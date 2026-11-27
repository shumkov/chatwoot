# frozen_string_literal: true

# Reads a conversation the way the Shumabit bridge reads it, so the loader trusts the same notes, counts the same
# eligible customer input and refuses the same text. Each predicate mirrors the bridge's assist helper, with
# JavaScript string semantics written out where Ruby's differ (whitespace, line starts, word boundaries, UTF-16
# length, truthiness).
class Umi::ShumabitReply::Evidence
  OUTCOMES = %w[reply no_reply needs_staff still_applies non_actionable unsupported failed invalid
                public_reply_sent resolved not_received_newer member_deleted interrupted].freeze
  FIELDS = %i[id message_type private sender_type sender_id status created_at content_attributes].freeze
  MAX_SAFE_INTEGER = (2**53) - 1
  OPTIONAL_ID_LISTS = %w[inspect_message_ids open_message_ids open_suffix origin_covered_message_ids].freeze

  # JavaScript's \s and String#trim set; Ruby's \s is ASCII only.
  JS_SPACE = '[\t\n\v\f\r    -     　﻿]'
  JS_LINE_START = '(?:\A|(?<=[\n\r  ]))'
  # JavaScript's \b without the u flag only knows ASCII word characters.
  ASCII_WORD_END = '(?![A-Za-z0-9_])'
  TRIM = /\A#{JS_SPACE}+|#{JS_SPACE}+\z/
  NOT_PLAIN = %r{```|</?[a-z][^>]*>}i
  LABEL_START = "#{JS_LINE_START}#{JS_SPACE}*".freeze
  STAFF_LABEL = /#{LABEL_START}(?:Staff only#{ASCII_WORD_END}|For Mai#{JS_SPACE}*:|Shumabit(?:#{JS_SPACE}+draft#{ASCII_WORD_END}|#{JS_SPACE}*[—:]))/i
  STAFF_COMMAND = %r{(?:\A|[^A-Za-z0-9_])/(?:back-in-stock|gift-card|send-product|draft-order|payment-qr)(?=\z|[^A-Za-z0-9_-])}i
  AGENT_MENTION = /@shumabit#{ASCII_WORD_END}/i

  Note = Struct.new(:message, :marker)

  class << self
    def read(conversation, bridge_user_id:)
      messages = Message.where(conversation_id: conversation.id).reorder(nil).select(*FIELDS).to_a
      new(messages, account_id: conversation.account_id, bridge_user_id: bridge_user_id)
    end

    def seen_digest(ids)
      Digest::SHA256.hexdigest("assist-seen-v1:#{ids.uniq.sort.join(',')}")
    end

    # A missing contact counts as redacted. Otherwise the flag is read with JavaScript truthiness, as the bridge's
    # assist snapshot reads it.
    def redacted?(contact)
      return true if contact.nil?

      value = contact.additional_attributes&.[]('umi_profile_redacted')
      !(value.nil? || value == false || value == 0 || value == '') # rubocop:disable Style/NumericPredicate
    end

    def text_check(text, limit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return 'empty' if !text.is_a?(String) || js_trim(text).empty?
      return 'too_long' if !limit || utf16_length(text) > limit
      return 'not_plain' if NOT_PLAIN.match?(text)
      return 'staff_label' if STAFF_LABEL.match?(text)
      return 'staff_command' if STAFF_COMMAND.match?(text)
      return 'agent_mention' if AGENT_MENTION.match?(text)

      nil
    end

    def marker(message, account_id, bridge_user_id) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      attributes = message.content_attributes
      marker = attributes['shumabit_draft']
      return unless message.private? && message.outgoing? && message.sender_type == 'User' && bridge_user_id &&
                    message.sender_id == bridge_user_id && attributes['deleted'] != true &&
                    attributes['shumabit_bridge'] == true && marker.is_a?(Hash)

      marker = marker.to_hash
      marker if valid_marker?(marker, account_id)
    end

    private

    def js_trim(text)
      text.gsub(TRIM, '')
    end

    def utf16_length(text)
      text.encode('UTF-16LE').bytesize / 2
    end

    def valid_marker?(marker, account_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return false unless marker['contract'] == 'assist-v1' && marker['policy_version'] == 'draft-v1'
      return false unless marker['row_key'].is_a?(String) && marker['row_key'].match?(/\A#{account_id}:[1-9]\d*\z/) &&
                          id?(marker['row_key'].split(':').last.to_i)

      covered = marker['covered_message_ids']
      return false unless ordered_ids?(covered) && id?(marker['source_message_id']) && covered.include?(marker['source_message_id'])
      return false unless safe_integer?(marker['eligible_after']) && !marker['eligible_after'].negative?
      return false unless marker['seen_digest'].is_a?(String) && marker['seen_digest'].match?(/\A[a-f0-9]{64}\z/)
      return false unless OUTCOMES.include?(marker['outcome'])
      return false unless OPTIONAL_ID_LISTS.all? { |key| !marker.key?(key) || ordered_ids?(marker[key], empty: true) }
      return false if %w[reply still_applies].include?(marker['outcome']) && !reply_fields?(marker)
      return true unless marker['outcome'] == 'still_applies'

      id?(marker['origin_note_id']) && ordered_ids?(marker['origin_covered_message_ids']) &&
        safe_integer?(marker['origin_created_at']) && !marker['origin_created_at'].negative?
    end

    def reply_fields?(marker)
      staff = marker['staff']
      marker['reply'].is_a?(String) && !js_trim(marker['reply']).empty? && marker.key?('staff') &&
        (staff.nil? || (staff.is_a?(String) && !js_trim(staff).empty?))
    end

    def ordered_ids?(value, empty: false)
      value.is_a?(Array) && (empty || value.any?) && value.all? { |item| id?(item) } && value == value.uniq.sort
    end

    def id?(value)
      safe_integer?(value) && value.positive?
    end

    def safe_integer?(value)
      value.is_a?(Integer) && value.abs <= MAX_SAFE_INTEGER
    end
  end

  def initialize(messages, account_id:, bridge_user_id:)
    @messages = messages
    @by_id = messages.index_by(&:id)
    @account_id = account_id
    @bridge_user_id = bridge_user_id
  end

  def message(id)
    @by_id[id]
  end

  # The newest public incoming or sent outgoing message, by whole-second time then id. Templates, activity rows,
  # private notes and failed replies never count.
  def tail
    @messages.select { |message| tail_candidate?(message) }.max_by { |message| [message.created_at.to_i, message.id] }
  end

  def eligible_ids(eligible_after)
    @eligible_ids ||= {}
    @eligible_ids[eligible_after] ||= @messages.select { |message| eligible?(message, eligible_after) }.map(&:id).sort
  end

  def trusted_notes
    @trusted_notes ||= begin
      notes = @messages.filter_map do |message|
        marker = self.class.marker(message, @account_id, @bridge_user_id)
        Note.new(message, marker) if marker
      end
      notes.sort_by { |note| [note.message.created_at.to_i, note.message.id] }
    end
  end

  # The newest trusted note made with knowledge of exactly the current eligible input.
  def current_note
    trusted_notes.reverse.find do |note|
      self.class.seen_digest(eligible_ids(note.marker['eligible_after'])) == note.marker['seen_digest']
    end
  end

  def uncovered_ids(eligible_after)
    eligible_ids(eligible_after) - trusted_notes.flat_map { |note| note.marker['covered_message_ids'] }
  end

  def live_note?(id)
    trusted_notes.any? { |note| note.message.id == id }
  end

  def newest_note_naming(id)
    trusted_notes.reverse.find { |note| note.marker['covered_message_ids'].include?(id) }
  end

  def deleted_member?(note)
    ids = note.marker['covered_message_ids'] + Array(note.marker['origin_covered_message_ids'])
    ids.any? { |id| (message = @by_id[id]).nil? || deleted?(message) }
  end

  private

  def tail_candidate?(message)
    !message.private? && (message.incoming? || (message.outgoing? && !message.failed?)) && !deleted?(message)
  end

  def eligible?(message, eligible_after)
    message.incoming? && !message.private? && message.sender_type == 'Contact' && !deleted?(message) &&
      message.created_at.to_i > eligible_after
  end

  def deleted?(message)
    message.content_attributes['deleted'] == true
  end
end
