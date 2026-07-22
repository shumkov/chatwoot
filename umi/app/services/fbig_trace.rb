# frozen_string_literal: true

# Structured trace for the Facebook / Instagram inbound message pipeline.
#
# Meta delivers each webhook once — a dropped message is gone permanently and
# the stock pipeline drops silently in several places (signature rejects,
# unknown channels, dedup, builder early-returns). Every decision point logs
# one grep-able line: `[UMI-FBIG] stage=<stage> key=value …`, so any missing
# message leaves a `rejected` / `dropped` / `error` line with a reason, and a
# healthy message leaves a `persisted` line.
#
# Tracing must never break the pipeline: field blocks are evaluated inside the
# helper's own rescue, log calls swallow their own errors (StandardError only —
# Sidekiq shutdown/interrupt signals must still propagate), and
# UMI_FBIG_TRACE_DISABLED=true turns everything into a no-op. Never log
# message text or payload bodies here — ids and mids only.
module Umi::FbigTrace
  DROP_STAGES = %i[rejected dropped error].freeze

  class << self
    # Fields whose computation could conceivably raise belong in the block —
    # it is evaluated inside this method's rescue, so a bad payload shape can
    # only lose the trace line, never affect the webhook/job control flow.
    def log(stage, **fields)
      return if ENV['UMI_FBIG_TRACE_DISABLED'] == 'true'

      fields = fields.merge(yield) if block_given?
      line = "[UMI-FBIG] stage=#{stage}"
      fields.each { |key, value| line += " #{key}=#{value}" unless value.nil? }

      DROP_STAGES.include?(stage) ? Rails.logger.warn(line) : Rails.logger.info(line)
    rescue StandardError
      nil
    end
  end

  # Webhooks::InstagramController — the stock signature check answers 401 with
  # zero logging; a rotated/misconfigured app secret silently rejects every
  # webhook until Meta disables the subscription.
  module InstagramSignature
    private

    def valid_meta_signature?
      result = super
      unless result
        Umi::FbigTrace.log(:rejected, channel: 'instagram', reason: 'signature') do
          { entry_ids: Array(params.to_unsafe_hash[:entry]).filter_map { |entry| entry[:id] }.join(',') }
        end
      end
      result
    end
  end

  # Webhooks::InstagramEventsJob — `next if channel.blank?` silently discards
  # events whose instagram_id matches no channel; and a crash anywhere in the
  # batch dies to the Sidekiq dead set with no grep-able ids.
  module InstagramJob
    def perform(entries)
      super
    rescue StandardError => e
      unless e.is_a?(MutexApplicationJob::LockAcquisitionError)
        Umi::FbigTrace.log(:error, channel: 'instagram', reason: e.class.name) do
          items = Array(entries).flat_map { |entry| entry.deep_symbolize_keys.values_at(:messaging, :standby).flatten.compact }
          { entry_ids: Array(entries).filter_map { |entry| entry.deep_symbolize_keys[:id] }.join(','),
            mids: items.filter_map { |item| item.dig(:message, :mid) }.join(',') }
        end
      end
      raise
    end

    private

    def find_channel(instagram_id)
      channel = super
      Umi::FbigTrace.log(:dropped, channel: 'instagram', reason: 'no_channel', instagram_id: instagram_id) if channel.blank?
      channel
    end
  end

  # Webhooks::FacebookEventsJob — a crash dies to the Sidekiq dead set with no
  # grep-able ids (the job argument is a JSON string).
  module FacebookJob
    def perform(message)
      super
    rescue StandardError => e
      unless e.is_a?(MutexApplicationJob::LockAcquisitionError)
        Umi::FbigTrace.log(:error, channel: 'facebook', reason: e.class.name) do
          messaging = JSON.parse(message)
          payload = messaging['messaging'] || messaging['standby'] || {}
          { sender: payload.dig('sender', 'id'), recipient: payload.dig('recipient', 'id'),
            mid: payload.dig('message', 'mid') }
        end
      end
      raise
    end
  end

  # Integrations::Facebook::MessageCreator — messages whose page_id matches no
  # Channel::FacebookPage vanish without a trace.
  module FacebookCreator
    def perform
      umi_trace_missing_page
      super
    end

    private

    def umi_trace_missing_page
      page_id = response.echo? ? response.sender_id : response.recipient_id
      return if Channel::FacebookPage.exists?(page_id: page_id)

      Umi::FbigTrace.log(:dropped, channel: 'facebook', reason: 'no_page', page_id: page_id, mid: response.identifier)
    rescue StandardError
      nil
    end
  end

  # Shared outcome trace for the Messenger-family builders: exactly one
  # `persisted` or `dropped` line per inbound message. The post-yield
  # classification is new code with no stock equivalent, so it carries its own
  # rescue; the reauth pre-check mirrors what stock #perform does anyway.
  module BuilderOutcome
    private

    def umi_trace_outcome(channel_label, mid)
      reauth = @inbox.channel.reauthorization_required?
      Umi::FbigTrace.log(:dropped, channel: channel_label, reason: 'reauth_required', inbox_id: @inbox.id, mid: mid) if reauth

      result = yield

      umi_trace_result(channel_label, mid) unless reauth
      result
    end

    def umi_trace_result(channel_label, mid)
      if @umi_dedup_skip
        Umi::FbigTrace.log(:dropped, channel: channel_label, reason: 'dedup', inbox_id: @inbox.id, mid: mid)
      elsif @message&.persisted?
        Umi::FbigTrace.log(:persisted, channel: channel_label, inbox_id: @inbox.id, mid: mid, message_id: @message.id)
      else
        Umi::FbigTrace.log(:dropped, channel: channel_label, reason: 'not_persisted', inbox_id: @inbox.id, mid: mid)
      end
    rescue StandardError
      nil
    end
  end

  module FacebookBuilder
    include BuilderOutcome

    def perform
      umi_trace_outcome('facebook', response.identifier) { super }
    end
  end

  module InstagramBuilder
    include BuilderOutcome

    def perform
      umi_trace_outcome('instagram', @messaging.dig(:message, :mid)) { super }
    end

    private

    def message_already_exists?
      @umi_dedup_skip = super
    end
  end
end
