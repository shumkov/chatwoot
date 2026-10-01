# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength
class Umi::Funnel::OperatorQueue
  InvalidParameters = Class.new(ArgumentError)
  TIMEZONE = 'Asia/Bangkok'
  PAGE_SIZE = 50
  CHANNELS = %w[Channel::FacebookPage Channel::Instagram Channel::Line Channel::Whatsapp Channel::Email Channel::WebWidget
                Channel::Telegram Channel::Sms Channel::TwilioSms].freeze
  MESSAGE_FIELDS = %i[id conversation_id inbox_id created_at message_type content_type private status sender_type sender_id].freeze
  PAYMENT_FIELDS = %w[classification review_reasons currency original_order_value current_order_value captured refunded net_cash
                      last_payment_at order_created_at order_updated_at paid_basket paid_history_unknown identity_hold].freeze

  def initialize(account_id:, since:, as_of: Time.current)
    @account_id = account_id
    @since = activation_time(since)
    @as_of = as_of
    raise InvalidParameters, 'Invalid activation boundary' unless @since && @since <= @as_of

    @inbox_ids = Umi::Funnel::ConversationClassifier.inbox_ids
    raise ActiveRecord::RecordNotFound unless Umi::Funnel::Configuration.account_ids.include?(@account_id)
  end

  def index(after_id: 0, through_id: nil)
    after_id = cursor(after_id)
    through_id = cursor(through_id) unless through_id.nil?
    snapshot do
      through_id ||= Account.find(@account_id).conversations.maximum(:id) || 0
      conversations = candidates.where(id: (after_id + 1)..through_id).order(:id).limit(PAGE_SIZE + 1).to_a
      more = conversations.size > PAGE_SIZE
      conversations = conversations.first(PAGE_SIZE)
      load_context(conversations)
      envelope.merge(timezone: TIMEZONE, business_open: business_open?, through_id: through_id,
                     next_after_id: more ? conversations.last.id : nil, coverage: coverage,
                     conversations: conversations.map { |conversation| row(conversation) })
    end
  end

  def show(display_id)
    snapshot do
      conversation = candidates.find_by!(display_id: display_id)
      load_context([conversation], detail: true)
      envelope.merge(conversation: row(conversation).merge(messages: message_rows(conversation), customer: customer(conversation),
                                                           commerce: commerce(conversation)))
    end
  end

  private

  def activation_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

    raise InvalidParameters, 'Activation boundary requires an ISO8601 timezone' unless value.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    Time.iso8601(value)
  rescue ArgumentError
    raise InvalidParameters, 'Invalid activation boundary'
  end

  def cursor(value)
    raise InvalidParameters, 'Invalid cursor' unless value.to_s.match?(/\A(?:0|[1-9]\d*)\z/)

    value.to_i
  end

  def snapshot
    connection = ApplicationRecord.connection
    isolation = connection.transaction_open? ? nil : :repeatable_read
    ApplicationRecord.transaction(isolation: isolation) do
      raise 'Operator queue requires repeatable-read isolation' unless connection.select_value('SHOW transaction_isolation') == 'repeatable read'

      yield
    end
  end

  def candidates
    scope = Conversation.where(account_id: @account_id, inbox_id: @inbox_ids).joins(:contact, :inbox)
                        .where(inboxes: { channel_type: CHANNELS })
                        .where("COALESCE(contacts.additional_attributes ->> 'umi_profile_redacted', 'false') != 'true'")
                        .where.not(id: Conversation.tagged_with('spam').select(:id))
    scope.where(status: %i[open pending snoozed]).or(scope.where(status: :resolved, updated_at: @since..))
         .preload(:contact, :inbox, :assignee)
  end

  def load_context(conversations, detail: false) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    ids = conversations.map(&:id)
    fields = MESSAGE_FIELDS + message_metadata + [Arel.sql("md5(COALESCE(content, '')) AS content_digest")]
    fields += [:content] if detail
    messages = Message.where(conversation_id: ids, created_at: ..@as_of).select(*fields).reorder(:created_at, :id).preload(:sender, :inbox).to_a
    @messages = messages.group_by(&:conversation_id)
    @attachments = Attachment.where(message_id: messages.map(&:id)).order(:id).to_a.group_by(&:message_id)
    @orders = Umi::ShopifyOrderAttribution.where(account_id: @account_id, conversation_id: ids, redacted_at: nil)
                                          .order(:id).to_a.group_by(&:conversation_id)
    @drafts = Umi::ShopifyDraftLink.where(account_id: @account_id, conversation_id: ids, redacted_at: nil)
                                   .order(:id).to_a.group_by(&:conversation_id)
    orders = @orders.values.flatten
    @financial = Umi::ShopifyOrderFinancialState.where(account_id: @account_id, shopify_order_id: orders.map(&:shopify_order_id), redacted_at: nil)
                                                .order(:id).to_a.index_by { |state| [state.shop_domain, state.shopify_order_id] }
  end

  def message_metadata
    # Message's store coder wraps its JSON as a string; select only timer facts, never embedded email bodies.
    attributes = "CASE WHEN json_typeof(content_attributes) = 'string' THEN (content_attributes #>> '{}')::json ELSE content_attributes END"
    keys = %w[deleted umi_recovered external_created_at automation_rule_id external_echo]
    pairs = keys.map { |key| "'#{key}', (#{attributes}) -> '#{key}'" }
    pairs << "'email', json_build_object('auto_reply', (#{attributes}) #> '{email,auto_reply}')"
    [Arel.sql("to_json(json_build_object(#{pairs.join(', ')})::text) AS content_attributes"),
     Arel.sql("jsonb_build_object('campaign_id', additional_attributes -> 'campaign_id') AS additional_attributes")]
  end

  def envelope
    { schema_version: 1, account_id: @account_id, as_of: @as_of.utc.iso8601(6) }
  end

  def coverage
    { inbox_ids: @inbox_ids, scope: 'configured_text_inboxes', since: @since.utc.iso8601(6),
      business_hours: { basis: 'daily_operator_schedule', timezone: TIMEZONE, opens_at: '09:00', closes_at: '21:00' },
      limitations: %w[ad_comments_not_verified attachments_not_interpreted current_persisted_context_not_live_commerce] }
  end

  def row(conversation)
    waiting, chronology = waiting(conversation)
    { id: conversation.id, display_id: conversation.display_id, inbox_id: conversation.inbox_id, status: conversation.status,
      snoozed_until: conversation.snoozed_until&.utc&.iso8601(6), assignee_name: conversation.assignee&.name,
      sales_status: conversation.custom_attributes['umi_sales_status'], revision: revision(conversation),
      active_since: active_since(conversation), waiting: waiting, chronology: chronology }
  end

  def active_since(conversation) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    message = visible_messages(conversation).find do |item|
      next false if item.created_at < @since || item.private? || item.content_attributes['umi_recovered'] == true

      (item.incoming? && !item.auto_reply_email?) || (item.outgoing? && !item.send(:bot_response?) && item.send(:human_response?))
    end
    message&.created_at&.utc&.iso8601(6)
  end

  def revision(conversation)
    messages = visible_messages(conversation)
    inputs = [conversation.attributes.slice('id', 'display_id', 'inbox_id', 'contact_id', 'status', 'snoozed_until', 'assignee_id'),
              conversation.custom_attributes['umi_sales_status'], conversation.contact.additional_attributes['umi_klaviyo_profile_id'],
              conversation.inbox.channel_type, conversation.assignee&.name, @inbox_ids, CHANNELS,
              message_rows(conversation, digest_content: true), messages.map(&:auto_reply_email?),
              customer(conversation), commerce(conversation), @since.utc.iso8601(6)]
    Digest::SHA256.hexdigest(inputs.to_json)
  end

  def waiting(conversation) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    waiting = nil
    first_response = true
    chronology = 'available'
    visible_messages(conversation).each do |message|
      next if message.private? || (!message.incoming? && !message.outgoing?)

      recovered = message.content_attributes['umi_recovered'] == true
      if message.incoming? && !message.auto_reply_email?
        if recovered
          chronology = 'unverifiable' unless waiting
        elsif message.created_at >= @since
          # A live incoming establishes a verifiable lower bound even if earlier imports have no reliable timestamp.
          chronology = 'available'
          waiting ||= { message_id: message.id, started_at: message.created_at.utc.iso8601(6),
                        business_seconds: business_seconds(message.created_at), first_response: first_response }
        end
      elsif successful_human?(message)
        waiting = nil
        chronology = recovered ? 'unverifiable' : 'available'
        first_response = false
      end
    end
    [waiting, chronology]
  end

  def successful_human?(message)
    message.outgoing? && !message.private? && !message.failed? && !message.send(:bot_response?) && message.send(:human_response?)
  end

  def visible_messages(conversation)
    Array(@messages[conversation.id]).reject { |message| message.content_attributes['deleted'] }
  end

  def message_rows(conversation, digest_content: false)
    visible_messages(conversation).map do |message|
      { id: message.id, created_at: message.created_at.utc.iso8601(6), direction: message.message_type, private: message.private?,
        delivery_status: message.failed? ? 'failed' : 'sent',
        human: message.send(:human_response?) && !message.send(:bot_response?),
        content: digest_content ? message[:content_digest] : message.content.to_s,
        attachment_types: Array(@attachments[message.id]).map(&:file_type),
        recovered: message.content_attributes['umi_recovered'] == true,
        source_created_at: message.content_attributes['external_created_at'] }
    end
  end

  def customer(conversation)
    contact = conversation.contact
    sync = contact.additional_attributes.fetch('umi_klaviyo_sync', {})
    { facts: contact.custom_attributes.slice(*Umi::Funnel::Configuration::CONTACT_FIELDS),
      identity: contact.additional_attributes['umi_klaviyo_profile_id'].present? ? 'resolved' : 'unresolved',
      sync: sync.slice('status', 'payment_snapshot_at', 'buyer_lifecycle', 'segments', 'service', 'revision'),
      sync_error: sync['error'].present?, basis: 'persisted_customer_context' }
  end

  def commerce(conversation)
    orders = Array(@orders[conversation.id]).select { |link| link.contact_id == conversation.contact_id }
    drafts = Array(@drafts[conversation.id]).select { |link| link.contact_id == conversation.contact_id }
    { basis: 'persisted_shopify_reconciliation_not_live_verification', orders: orders.map { |link| order_context(link) },
      drafts: drafts.map { |link| link.attributes.slice('shopify_draft_id', 'shopify_order_id', 'name', 'status', 'last_checked_at', 'updated_at') } }
  end

  def order_context(link)
    state = @financial[[link.shop_domain, link.shopify_order_id]]
    { order_id: link.shopify_order_id, name: link.shopify_order_name, attribution_state: link.attribution_state,
      linked_at: link.linked_at, updated_at: link.updated_at,
      payment: state && { facts: state.snapshot.slice(*PAYMENT_FIELDS), reconciled_at: state.reconciled_at,
                          requested_at: state.reconciliation_requested_at, error: state.last_error.present? } }
  end

  def business_open?
    (9...21).cover?(@as_of.in_time_zone(TIMEZONE).hour)
  end

  def business_seconds(start)
    from = start.in_time_zone(TIMEZONE)
    to = @as_of.in_time_zone(TIMEZONE)
    days = (to.to_date - from.to_date).to_i
    first_elapsed = (from - from.change(hour: 9)).clamp(0, 12.hours)
    last_elapsed = (to - to.change(hour: 9)).clamp(0, 12.hours)
    # Bangkok's daily schedule has no DST: whole days contribute exactly twelve hours.
    (days * 12.hours) + last_elapsed - first_elapsed
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength
