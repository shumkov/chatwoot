# frozen_string_literal: true

# Asks the bridge, through the listener its account webhook already uses, how it has handled given customer messages.
# The answer is metadata only. Anything outside the documented shape counts as no answer, so the loader fails closed.
class Umi::ShumabitReply::StatusClient
  include HTTParty

  CLASSES = %w[reserved active attempted ended unknown].freeze
  STATUSES = %w[queued running posting ambiguous held_ambiguous done ignored stale failed interrupted redacted none].freeze
  NOTE_STATUSES = %w[posting ambiguous done].freeze
  TERMINAL_REASONS = %w[source_ineligible reply_posted engine_reported_delivery superseded_before_read stale_before_engine
                        no_draft draft_already_exists stale_after_engine draft_posted draft_post_reconciled
                        publication_readback_missing source_read_failed context_read_failed engine_failed result_invalid
                        prepublication_read_failed session_save_failed state_save_failed publication_failed
                        publication_readback_failed restart_interrupted restart_draft_found restart_readback_failed
                        outcome_posted still_applies_posted non_actionable_posted unsupported_posted disposition_posted
                        validation_failed already_covered already_attempted empty_batch redacted held_ambiguous].freeze
  VALIDATION_CODES = (%w[invalid_json invalid_shape bare_no_draft too_large] +
                      %w[empty not_plain staff_label staff_command agent_mention too_long].map { |rule| "text_check:#{rule}" }).freeze
  FIELDS = %w[draft_status terminal_reason note_id disposition validation_code output_bytes note_status conversation_busy
              conversation_ambiguous message_classes].freeze
  MAX_OUTPUT_BYTES = 4 * 1024 * 1024
  NETWORK_ERRORS = [Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError, HTTParty::Error,
                    Net::HTTPBadResponse].freeze

  Result = Struct.new(:classes, :ambiguous)

  def initialize(base_url)
    @url = "#{base_url.chomp('/')}/webhook"
  end

  def call(account_id:, display_id:, tail_id:, message_ids:)
    body = { event: 'umi_draft_status', account: { id: account_id }, conversation: { id: display_id },
             tail_message_id: tail_id, message_ids: message_ids }
    response = self.class.post(@url, body: body.to_json, headers: { 'Content-Type' => 'application/json' },
                                     follow_redirects: false, open_timeout: 2, read_timeout: 3)
    response.code == 200 ? parse(response.body, message_ids) : nil
  rescue *NETWORK_ERRORS => e
    # The exception message can carry the bridge address; the class is enough to diagnose.
    Rails.logger.warn("[umi-shumabit-reply] status unavailable: #{e.class}")
    nil
  end

  private

  def parse(text, message_ids)
    data = JSON.parse(text.to_s)
    return unless data.is_a?(Hash) && FIELDS.all? { |field| data.key?(field) } && valid?(data, message_ids)

    Result.new(data['message_classes'].transform_keys(&:to_i), data['conversation_ambiguous'])
  rescue JSON::ParserError
    nil
  end

  def valid?(data, message_ids) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    STATUSES.include?(data['draft_status']) &&
      (data['terminal_reason'].nil? || TERMINAL_REASONS.include?(data['terminal_reason'])) &&
      (data['note_id'].nil? || (data['note_id'].is_a?(Integer) && data['note_id'].positive?)) &&
      (data['disposition'].nil? || Umi::ShumabitReply::Evidence::OUTCOMES.include?(data['disposition'])) &&
      (data['validation_code'].nil? || VALIDATION_CODES.include?(data['validation_code'])) &&
      (data['output_bytes'].nil? || (data['output_bytes'].is_a?(Integer) && data['output_bytes'].between?(0, MAX_OUTPUT_BYTES))) &&
      (data['note_status'].nil? || NOTE_STATUSES.include?(data['note_status'])) &&
      [true, false].include?(data['conversation_busy']) && [true, false].include?(data['conversation_ambiguous']) &&
      classes?(data['message_classes'], message_ids)
  end

  def classes?(classes, message_ids)
    classes.is_a?(Hash) && classes.keys.sort == message_ids.map(&:to_s).sort && classes.values.all? { |value| CLASSES.include?(value) }
  end
end
