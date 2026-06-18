# frozen_string_literal: true

# On a Twilio recording-status callback, enqueue the download/attach job once the
# recording is complete.
class Umi::Voice::RecordingStatusService
  def initialize(account:, payload:)
    @account = account
    @payload = payload || {}
  end

  def perform
    return unless @payload['RecordingStatus'] == 'completed'

    sid = @payload['RecordingSid']
    url = @payload['RecordingUrl']
    return if sid.blank? || url.blank?

    call = Umi::Call.find_by(account_id: @account.id, provider: :twilio, provider_call_id: @payload['CallSid'])
    return if call.nil?

    Umi::Voice::RecordingAttachmentJob.perform_later(call.id, sid, url, @payload['RecordingDuration'])
  end
end
