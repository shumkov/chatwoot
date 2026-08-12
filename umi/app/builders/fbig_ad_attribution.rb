# frozen_string_literal: true

# Captures Meta's ad `referral` object on inbound Facebook/Instagram messages,
# mirroring the shape upstream already accepts for WhatsApp and Twilio.
#
# Meta nests the object inside `message`, not alongside it:
#
#   {"sender" => …, "recipient" => …, "timestamp" => …,
#    "message" => {"mid" => …, "text" => "1. สนใจรับส่วนลด 10%…",
#                  "referral" => {"source" => "ADS", "type" => "OPEN_THREAD",
#                                 "ad_id" => "120252251820030415",
#                                 "ads_context_data" => {"ad_title" => "Video_2", …}}}}
#
# Reading the top-level key instead returns nil, which is indistinguishable
# from an organic conversation — so the nesting is load-bearing, not a detail.
#
# Two layers, answering different questions:
#   * the message keeps the whole object as an immutable record of what arrived
#   * the conversation keeps the three readable fields, so agents and
#     automation rules can see which ad a conversation came from
#
# The conversation write happens AFTER the builder's transaction commits. A
# rescued database error inside that transaction would leave it aborted and the
# customer's message would still die at COMMIT — the failure mode
# `Umi::MessengerAttachmentResilience` documents. Nothing here may cost a
# customer message.
module Umi::FbigAdAttribution
  CONVERSATION_KEYS = %w[meta_ad_id meta_ad_ref meta_ad_title].freeze

  module_function

  def normalize(raw)
    raw.to_h.deep_stringify_keys.presence
  end

  # Meta reuses `message.referral` for Instagram Shops product taps, which carry
  # a `product` object and no ad at all. Only ad referrals get promoted; the raw
  # object is still stored on the message either way.
  def from_ads?(referral)
    referral['source'] == 'ADS'
  end

  # `ref` is set per-ad by whoever builds the campaign and is absent unless they
  # set it — so this degrades to ad_id alone rather than capturing nothing.
  def conversation_pairs(referral)
    {
      'meta_ad_id' => referral['ad_id'],
      'meta_ad_ref' => referral['ref'],
      'meta_ad_title' => referral.dig('ads_context_data', 'ad_title')
    }.transform_values { |value| value.presence&.to_s }.compact
  end

  def promote(message, referral)
    return if referral.blank? || !from_ads?(referral)

    pairs = conversation_pairs(referral)
    return if pairs.blank?

    conversation = message.conversation
    # Lock before reading so a sidebar update already in flight commits first.
    # The model save remains intentional: its conversation_updated callback is
    # the automation/webhook fanout for this post-commit attribution write.
    conversation.reload
    conversation.with_lock do
      conversation.reload
      # Clear all three before writing. A plain merge would leave a previous
      # ad's title beside a new ad's id, describing an ad that never existed.
      conversation.update!(
        custom_attributes: conversation.custom_attributes.except(*CONVERSATION_KEYS).merge(pairs)
      )
    end
    log(:referral_promoted, conversation.id, pairs)
  end

  # Erasure counterpart to `promote`. Ad attribution is behavioural data — which
  # ad this person clicked, and when — and the contact_inbox source_id survives
  # erasure because it is how the channel routes messages, so leaving it behind
  # is re-identifying.
  #
  # Message#save! is avoided throughout: it would trip prevent_message_flooding
  # on an active conversation, and would fire MESSAGE_UPDATED webhooks echoing
  # the redaction outward to third parties. `update_all` and `update_columns`
  # both skip validations and callbacks, so either satisfies that.
  #
  # conversations.custom_attributes is `jsonb` and takes `-` directly.
  #
  # messages.content_attributes cannot be touched in SQL at all. It is a `json`
  # column carrying `store … coder: JSON`, so the value is serialized twice and
  # what Postgres holds is a JSON *string*:
  #
  #   content_attributes::text                 "{\"referral\":{…}}"   ← quoted
  #   jsonb_typeof(content_attributes::jsonb)  "string"
  #
  # Every key operator therefore matches nothing — silently. A predicate of
  # `content_attributes::jsonb -> 'referral' IS NOT NULL` returned 0 rows in
  # production against 5029 rows that genuinely carry the key, and the erasure
  # reported success while deleting nothing. Reading through the accessor, which
  # decodes, and writing back through `update_columns`, which re-encodes the
  # same way, is the only form that cannot silently miss.
  def purge_for(contact)
    ActiveRecord::Base.transaction do
      conversation_ids = contact.conversations.pluck(:id)
      next if conversation_ids.empty?

      Conversation.where(id: conversation_ids)
                  .update_all("custom_attributes = custom_attributes - #{CONVERSATION_KEYS.map { |k| "'#{k}'" }.join(' - ')}") # rubocop:disable Rails/SkipsModelValidations
      purge_message_referrals(conversation_ids)
    end
  end

  def purge_message_referrals(conversation_ids)
    Message.where(conversation_id: conversation_ids).find_each do |message|
      attributes = message.content_attributes
      next if attributes['referral'].blank?

      # rubocop:disable Rails/SkipsModelValidations
      message.update_columns(content_attributes: attributes.except('referral'))
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def log(stage, conversation_id, pairs = {})
    Rails.logger.info(
      "[UMI-FBIG] stage=#{stage} conversation=#{conversation_id} " \
      "ad_id=#{pairs['meta_ad_id'] || '-'} ref=#{pairs['meta_ad_ref'] || '-'}"
    )
  rescue StandardError
    nil
  end

  # Reads the referral off the parsed Facebook payload. The parser keeps
  # `@messaging` private and exposes no accessor for it.
  module MessageParser
    def message_referral
      @messaging&.dig('message', 'referral')
    end
  end

  # Shared by both platform builders: store on the message inside the
  # transaction (pure in-memory, cannot poison it), promote to the conversation
  # after it commits.
  module Builder
    def perform
      result = super
      umi_promote_ad_referral
      result
    end

    private

    def umi_promote_ad_referral
      return if @outgoing_echo
      return unless @message&.persisted?

      referral = Umi::FbigAdAttribution.normalize(umi_raw_referral)
      if referral.blank?
        # Only worth a line once per conversation, not on every reply.
        Umi::FbigAdAttribution.log(:referral_absent, @message.conversation_id) if @message.conversation.previously_new_record?
        return
      end

      Umi::FbigAdAttribution.promote(@message, referral)
    rescue StandardError => e
      # Deliberately swallowed: the message is already committed and an
      # attribution failure must never look like a message failure.
      umi_report_attribution_failure(:referral_promote_failed, e)
    end

    def umi_message_params_with_referral(params)
      referral = Umi::FbigAdAttribution.normalize(umi_raw_referral)
      return params if referral.blank? || @outgoing_echo

      params.merge(content_attributes: params[:content_attributes].to_h.merge(referral: referral))
    rescue StandardError => e
      umi_report_attribution_failure(:referral_capture_failed, e)
      params
    end

    def umi_report_attribution_failure(stage, error)
      Rails.logger.warn("[UMI-FBIG] stage=#{stage} error=#{error.class}: #{error.message}")
      ChatwootExceptionTracker.new(error, account: @inbox.account).capture_exception
    rescue StandardError
      # Attribution is enrichment and observability, never part of message
      # persistence. A broken logger or tracker must be equally harmless.
      nil
    end
  end

  module FacebookBuilder
    include Builder

    private

    def umi_raw_referral
      @response.try(:message_referral)
    end

    def message_params
      umi_message_params_with_referral(super)
    end
  end

  # Covers both Instagram builder subclasses — neither overrides `message_params`
  # or `perform`.
  module InstagramBuilder
    include Builder

    private

    def umi_raw_referral
      @messaging.dig(:message, :referral)
    end

    def message_params
      umi_message_params_with_referral(super)
    end
  end
end
