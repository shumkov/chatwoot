# frozen_string_literal: true

class Umi::Shopify::CommerceController < Api::V1::Accounts::Conversations::BaseController
  before_action :commerce_context
  around_action :serialize_customer_identity, only: %i[show customer create]
  rescue_from Umi::Shopify::CommerceError, with: :commerce_error

  def show
    result = { customer: nil, orders: { items: [], cursor: nil }, drafts: { items: [], cursor: nil },
               draft_access: nil, linked: linked_objects }
    render json: result.merge(remote_commerce)
  rescue Umi::Shopify::CommerceError => e
    render json: result.merge(error: e.message)
  end

  def customers
    render json: reader.customers(params[:query], after: params[:after])
  end

  def customer
    authorize @contact, :update?
    selected = reader.fetch('customer', params.require(:customer_id))
    Umi::Shopify::ManualLinkService.link_customer(@contact, selected)
    render json: { customer: selected }
  end

  def preview
    object = selected_object
    raise Umi::Shopify::CommerceError, 'invalid_reference' if object['kind'].nil?

    attribution = Umi::ShopifyOrderAttribution.find_by(account_id: Current.account.id, shopify_order_id: object['id']) if object['kind'] == 'order'
    candidate = Current.account.conversations.find_by(id: attribution&.candidate_conversation_id)
    render json: object.merge('candidate_conversation' => candidate&.display_id)
  end

  def create
    object = selected_object
    raise Umi::Shopify::CommerceError, 'invalid_reference' unless %w[order draft].include?(object['kind'])
    raise Umi::Shopify::CommerceError, 'stale_preview' unless params.require(:updated_at) == object['updated_at']

    link = link_service.link(object)
    Umi::Shopify::DraftLinkReconcileJob.perform_later(link.id) if object['kind'] == 'draft'
    render json: { linked: true }
  end

  def destroy
    raise Umi::Shopify::CommerceError, 'invalid_reference' unless %w[order draft].include?(params[:kind])

    link_service.unlink(params[:kind], params.require(:id))
    head :no_content
  end

  def refresh
    draft_links.each { |link| Umi::Shopify::DraftLinkReconcileJob.perform_later(link.id, refresh: true) }
    order_links.each do |link|
      Umi::Shopify::OrderFinancialStateService.request(account_id: Current.account.id, shop_domain: @hook.reference_id,
                                                       order_id: link.shopify_order_id)
    end
    head :accepted
  end

  private

  # Serialize identity reads/writes with erasure while allowing event foreign-key checks.
  def serialize_customer_identity(&)
    Current.account.with_lock('FOR NO KEY UPDATE', &)
  end

  def remote_commerce
    customer_id = linked_customer_id
    access = reader.draft_access?
    {
      customer: customer_id.present? ? reader.fetch('customer', customer_id) : nil,
      orders: reader.history(customer_id, kind: 'order', after: params[:orders_after]),
      drafts: access ? reader.history(customer_id, kind: 'draft', after: params[:drafts_after]) : { items: [], cursor: nil },
      draft_access: access
    }
  end

  def commerce_context
    return head :forbidden unless Current.user.is_a?(User)

    @contact = @conversation.contact
    @hook = Integrations::Hook.where(account_id: Current.account.id, app_id: 'shopify', status: :enabled).sole
    raise Umi::Shopify::CommerceError, 'redacted' if @contact.additional_attributes['umi_profile_redacted']
  end

  def reader
    @reader ||= Umi::Shopify::CommerceReader.new(@hook)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def linked_customer_id
    existing = @contact.additional_attributes['shopify_customer_id']
    return existing if existing.present?

    terms = []
    terms << "email:#{@contact.email}" if @contact.email.present?
    terms << "phone:#{@contact.phone_number}" if @contact.phone_number.present?
    return if terms.empty?

    result = reader.customers(terms.join(' OR '))
    matches = result[:items].select do |candidate|
      (@contact.email.present? && candidate['email'].to_s.casecmp?(@contact.email)) ||
        (@contact.phone_number.present? && candidate['phone'] == @contact.phone_number)
    end
    return unless matches.one? && result[:cursor].nil?

    @contact.with_lock do
      Umi::Shopify::ManualLinkService.link_customer(@contact, matches.first) if @contact.additional_attributes['shopify_customer_id'].blank?
      @contact.additional_attributes['shopify_customer_id']
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def link_service
    Umi::Shopify::ManualLinkService.new(conversation: @conversation, actor: Current.user)
  end

  def selected_object
    kind, id = reader.reference(params.require(:reference))
    reader.fetch(kind, id)
  end

  def order_links
    Umi::ShopifyOrderAttribution.verified.where(account_id: Current.account.id, shop_domain: @hook.reference_id.downcase,
                                                conversation_id: @conversation.id, contact_id: @contact.id)
  end

  def draft_links
    Umi::ShopifyDraftLink.active.where(account_id: Current.account.id, shop_domain: @hook.reference_id.downcase,
                                       conversation_id: @conversation.id, contact_id: @contact.id)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def linked_objects
    drafts = draft_links.to_a
    links = order_links.to_a
    states = Umi::ShopifyOrderFinancialState.where(account_id: Current.account.id, shop_domain: @hook.reference_id.downcase,
                                                   shopify_order_id: links.map(&:shopify_order_id)).includes(:paid_event).index_by(&:shopify_order_id)
    drafts_by_order = drafts.index_by(&:shopify_order_id)
    orders = links.map do |link|
      state = states[link.shopify_order_id]
      { kind: 'order', id: link.shopify_order_id, name: link.shopify_order_name, amount: link.order_total, currency: link.currency,
        status: state&.snapshot&.[]('classification'), error: state&.last_error ? 'shopify_unavailable' : state&.snapshot&.[]('identity_hold'),
        source: link.source, paid: state&.paid_event&.conversation_id.present?,
        draft_name: drafts_by_order[link.shopify_order_id]&.name,
        admin_url: "https://#{@hook.reference_id}/admin/orders/#{link.shopify_order_id}" }
    end
    orders + drafts.reject { |link| link.status == 'resolved' }.map do |link|
      { kind: 'draft', id: link.shopify_draft_id, name: link.name, status: link.status, error: link.last_error,
        source: 'operator', paid: false, admin_url: "https://#{@hook.reference_id}/admin/draft_orders/#{link.shopify_draft_id}" }
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def commerce_error(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
