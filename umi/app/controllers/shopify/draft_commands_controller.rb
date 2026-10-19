# frozen_string_literal: true

class Umi::Shopify::DraftCommandsController < Api::V1::Accounts::Conversations::BaseController
  before_action :bridge_context
  around_action :serialize_customer_identity
  rescue_from ArgumentError, Umi::Shopify::CommerceError, with: :invalid_command

  def show
    @source.with_lock do
      @command = Umi::Shopify::DraftCommand.parse!(@source)
      render json: current_receipt
    end
  end

  # rubocop:disable Metrics/AbcSize
  def create
    @source.with_lock do
      @command = Umi::Shopify::DraftCommand.parse!(@source)
      raise ArgumentError, 'Only an explicit create command can link a new draft' unless @command[:type] == 'draft' && !@command[:preview]

      @contact.with_lock do
        @conversation.reload
        unless @conversation.contact_id == @contact.id && params.require(:contact_id).to_s == @contact.id.to_s
          raise ArgumentError, 'Conversation customer changed'
        end

        id = params.require(:draft_order_id).to_s
        existing = @source.content_attributes['umi_created_draft_id']
        raise ArgumentError, 'Source already linked to a different draft' if existing && existing != id

        object = Umi::Shopify::DraftCommand.read!(@hook, id, @command, marker, customer_id)
        link = Umi::Shopify::ManualLinkService.new(conversation: @conversation, actor: @source.sender).link(object)
        @source.update!(content_attributes: @source.content_attributes.merge('umi_created_draft_id' => id))
        Umi::Shopify::DraftLinkReconcileJob.perform_later(link.id)
        render json: current_receipt
      end
    end
  end

  # rubocop:enable Metrics/AbcSize

  private

  def serialize_customer_identity(&)
    Current.account.with_lock('FOR NO KEY UPDATE', &)
  end

  # rubocop:disable Metrics/AbcSize
  def bridge_context
    allowed = [ENV.fetch('UMI_COMMERCE_META_INBOX_ID', '2').to_i, ENV.fetch('UMI_COMMERCE_CLOUD_INBOX_ID', '3').to_i]
    return head :forbidden unless Current.user.is_a?(User) && Current.user.id.to_s == ENV['UMI_COMMERCE_BRIDGE_USER_ID'] &&
                                  Current.account.id == ENV.fetch('UMI_COMMERCE_ACCOUNT_ID', '1').to_i && allowed.include?(@conversation.inbox_id)

    @source = @conversation.messages.find(params.require(:source_message_id))
    @contact = @conversation.contact
    @hook = Integrations::Hook.where(account_id: Current.account.id, app_id: 'shopify', status: :enabled).sole
  end

  # rubocop:enable Metrics/AbcSize

  def customer_id
    raise ArgumentError, 'Customer is redacted' if @contact.additional_attributes['umi_profile_redacted']

    id = @contact.additional_attributes['shopify_customer_id'].presence
    id && "gid://shopify/Customer/#{id}"
  end

  def marker
    "umi-cw-a#{Current.account.id}-c#{@conversation.display_id}-m#{@source.id}"
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def current_receipt
    @conversation.reload
    @contact.reload
    raise ArgumentError, 'Conversation customer changed' unless @conversation.contact_id == @contact.id

    result = { status: 'ready', contact_id: @contact.id, customer_id: customer_id, shop_domain: @hook.reference_id, linked_purchase: nil }
    if @command[:type] == 'qr'
      link = purchase_link(@command[:kind], @command[:id])
      raise ArgumentError, 'Purchase is not linked to this conversation and customer' unless link

      result[:linked_purchase] = { kind: @command[:kind], id: @command[:id], customer_id: link.shopify_customer_id&.then do |id|
        "gid://shopify/Customer/#{id}"
      end }
      raise ArgumentError, 'Linked purchase customer changed' unless result[:linked_purchase][:customer_id] == result[:customer_id]
    elsif (id = @source.content_attributes['umi_created_draft_id'])
      raise ArgumentError, 'Draft linkage changed; inspect before repeating' unless purchase_link('draft', id.split('/').last)

      result[:status] = 'linked'
      result[:draft_order_id] = id
    end
    result
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def purchase_link(kind, id)
    scope = { account_id: Current.account.id, shop_domain: @hook.reference_id.downcase, conversation_id: @conversation.id, contact_id: @contact.id }
    return Umi::ShopifyDraftLink.active.where(scope).find_by(shopify_draft_id: id, status: 'pending') if kind == 'draft'

    Umi::ShopifyOrderAttribution.verified.where(scope).find_by(shopify_order_id: id)
  end

  def invalid_command(error)
    render json: { status: 'held', text: error.message }, status: :unprocessable_entity
  end
end
