# frozen_string_literal: true

class Umi::Funnel::CustomerProjection
  KEY = 'umi_customer_projection'
  NOTE_MARKER = 'umi_customer_summary'

  def self.state(contact)
    attributes = contact.custom_attributes
    labels = []
    stage = attributes['umi_funnel_stage']
    labels << stage if %w[chooser seeker client repeat].include?(stage)
    labels << 'barter' if attributes['umi_barter_history'] == true
    Umi::Funnel::Configuration::ROLES.each { |key, label| labels << label if attributes[key] == 'yes' }
    { 'contact_id' => contact.id, 'binding' => contact.additional_attributes['umi_klaviyo_profile_id'],
      'revision' => contact.additional_attributes.dig('umi_klaviyo_sync', 'revision') || 0, 'labels' => labels,
      'facts' => attributes.slice(*Umi::Funnel::Configuration::CONTACT_FIELDS),
      'freshness' => contact.additional_attributes.dig('umi_klaviyo_sync', 'status'), 'service' => service_state(contact) }
  end

  def self.service_state(contact)
    sync = contact.additional_attributes.fetch('umi_klaviyo_sync', {})
    service = sync.fetch('service', {})
    at = Time.iso8601(service.fetch('observed_at').to_s)
    fresh = sync['error'].blank? && at > 2.hours.ago && at <= Time.current
    { 'state' => service.fetch('state'), 'freshness' => fresh ? 'fresh' : 'stale' }
  rescue KeyError, ArgumentError
    { 'state' => 'unknown', 'freshness' => 'unknown' }
  end

  def self.assign(conversation, contact, current_labels: conversation.label_list)
    projection = state(contact)
    previous = conversation.additional_attributes[KEY].to_h
    conversation.label_list = (current_labels - Umi::Funnel::Configuration::CUSTOMER_LABELS) | projection['labels']
    conversation.additional_attributes = conversation.additional_attributes.merge(KEY => projection.merge(previous.slice('summary')))
    # Lifecycle projection runs after the tag cache's before_save callback.
    conversation.send(:save_cached_tag_list)
  end

  def self.apply!(conversation, contact, initial: false, classification: nil, historical: false) # rubocop:disable Metrics/CyclomaticComplexity
    return if contact.additional_attributes['umi_profile_redacted']
    return if !historical && conversation.resolved? && (!initial || !conversation.additional_attributes[KEY])

    assign(conversation, contact) if historical || !conversation.resolved?
    summarize!(conversation, contact, classification: classification)
    conversation.save!
  end

  def self.summarize!(conversation, contact, classification: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    projection = conversation.additional_attributes.fetch(KEY)
    signature = summary_content(projection, contact)
    previous = projection['summary']
    previous = summary_content(previous, contact) if previous.is_a?(Hash)
    return if previous == signature && classification.nil? && projection['summary'] == signature

    if (previous != signature || classification) && (signature.present? || previous.present? || classification)
      write_note!(conversation, contact, classification: classification)
    end
    projection['summary'] = signature
    conversation.additional_attributes = conversation.additional_attributes.merge(KEY => projection)
  end

  def self.invalidate!(contact, binding: contact.additional_attributes['umi_klaviyo_profile_id'], erased: false)
    contact.conversations.order(:id).each do |conversation|
      conversation.with_lock do
        owner = conversation.additional_attributes[KEY]
        next unless owner && owner['contact_id'] == contact.id && owner['binding'] == binding

        conversation.label_list -= Array(owner['labels'])
        conversation.additional_attributes = conversation.additional_attributes.except(KEY)
        conversation.save!
        next if erased

        conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id,
                                      message_type: :outgoing, private: true, sender: nil,
                                      content: 'Customer identity corrected; the previous customer labels have been removed.',
                                      content_attributes: { NOTE_MARKER => { 'contact_id' => contact.id } })
      end
    end
  end

  def self.summary_content(projection, contact) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    attributes = projection.fetch('facts')
    lines = []
    stage = attributes['umi_funnel_stage']
    lines << "Customer: #{stage}." if %w[chooser seeker client repeat].include?(stage)
    count = attributes['umi_paid_order_count']
    if count&.positive?
      prefix = attributes['umi_paid_history_complete'] ? '' : 'At least '
      lines << "#{prefix}#{count} confirmed paid #{count == 1 ? 'order' : 'orders'}."
    end
    Umi::Funnel::Configuration::ROLES.each do |key, label|
      lines << "#{label}: yes." if attributes[key] == 'yes'
    end
    lines << 'Barter history: yes (order marked barter).' if attributes['umi_barter_history'] == true
    service = projection.fetch('service', {})
    lines << "Service reservation: #{service['state']} (fresh)." if %w[hold clear].include?(service['state']) && service['freshness'] == 'fresh'
    if contact.additional_attributes.dig('umi_klaviyo_sync', 'error').to_s.start_with?('identity_unresolved')
      lines << 'Customer identity unresolved; verify email or phone, or link an existing profile.'
    end
    lines.join("\n")
  end

  def self.write_note!(conversation, contact, classification: nil)
    content = summary_content(conversation.additional_attributes.fetch(KEY), contact)
    if content.blank? && !classification
      content = 'Previously noted customer context is no longer verified; check current attributes before relying on the earlier note.'
    end
    content = [content, classification.fetch(:text)].reject(&:blank?).join("\n") if classification
    create_note!(conversation, contact, content, classification)
  end

  def self.create_note!(conversation, contact, content, classification = nil)
    marker = { 'contact_id' => contact.id }
    marker.merge!(classification.except(:text).stringify_keys) if classification
    conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id,
                                  message_type: :outgoing, private: true, sender: nil, content: content,
                                  content_attributes: { NOTE_MARKER => marker })
  end
end
