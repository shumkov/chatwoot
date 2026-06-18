# frozen_string_literal: true

# Downloads a Twilio call recording (SSRF-safe, audio-only) and attaches it to the Call,
# idempotently. Touches the message so the recording_url is rebroadcast.
class Umi::Voice::RecordingAttachmentJob < ApplicationJob
  queue_as :low
  retry_on SafeFetch::FetchError, wait: 5.seconds, attempts: 3

  ALLOWED_CONTENT_TYPE_PREFIXES = %w[audio/].freeze

  def perform(call_id, recording_sid, recording_url, recording_duration = nil)
    call = Umi::Call.find_by(id: call_id)
    return if call.nil? || recording_sid.blank? || recording_url.blank?
    return if already_attached?(call, recording_sid)

    channel = call.inbox.channel
    SafeFetch.fetch(recording_url,
                    http_basic_authentication: [channel.account_sid, channel.auth_token],
                    allowed_content_type_prefixes: ALLOWED_CONTENT_TYPE_PREFIXES) do |result|
      persist!(call, result, recording_sid, recording_duration)
    end
    call.message&.touch # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def already_attached?(call, recording_sid)
    call.recording.attached? && call.recording_sid.to_s == recording_sid.to_s
  end

  def persist!(call, result, recording_sid, recording_duration)
    call.with_lock do
      next if already_attached?(call, recording_sid)

      call.recording.attach(io: result.tempfile, filename: "#{recording_sid}.#{extension(result)}", content_type: result.content_type)
      call.recording_sid = recording_sid
      call.duration_seconds ||= recording_duration.to_i if recording_duration.present?
      call.save!
    end
  end

  def extension(result)
    result.content_type.to_s.include?('mpeg') ? 'mp3' : 'wav'
  end
end
