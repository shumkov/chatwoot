# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Fbig::ContactInboxPlatformEvidence
  INSTAGRAM_TYPE = 'instagram_direct_message'
  PLATFORMS = %w[messenger instagram].freeze
  MARKER_KEYS = %w[schema_version platform thread_id configuration].to_set.freeze
  CONFIGURATION_KEYS = %w[since before outbound_policy].to_set.freeze

  def self.classify(contact_inbox)
    evidence = contact_inbox.conversations.each_with_object(Set.new) do |conversation, platforms|
      attributes = conversation.additional_attributes
      platforms << (attributes['type'] == INSTAGRAM_TYPE ? :instagram : :messenger)
      marker_platform = exact_marker_platform(conversation, attributes['umi_history_import'])
      platforms << marker_platform.to_sym if marker_platform
    end
    return :unknown if evidence.empty?
    return evidence.first if evidence.one?

    :ambiguous
  end

  def self.exact_marker_platform(conversation, marker)
    return unless marker.is_a?(Hash) &&
                  marker.keys.to_set == MARKER_KEYS &&
                  marker['schema_version'] == Umi::Fbig::HistoryImportService::SCHEMA_VERSION &&
                  marker['platform'].in?(PLATFORMS) &&
                  marker['thread_id'].to_s.present? &&
                  marker['configuration'].is_a?(Hash) &&
                  marker['configuration'].keys.to_set == CONFIGURATION_KEYS

    platform = marker['platform']
    expected_identifier = "umi-fbig-history:#{conversation.inbox_id}:#{platform}:#{marker['thread_id']}"
    platform if conversation.identifier == expected_identifier
  end
  private_class_method :exact_marker_platform
end
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
