# frozen_string_literal: true

# Maps a Twilio CallStatus webhook to our internal status and delegates to the manager.
class Umi::Voice::StatusUpdateService
  TWILIO_STATUS_MAP = {
    'queued' => 'ringing', 'initiated' => 'ringing', 'ringing' => 'ringing',
    'in-progress' => 'in_progress', 'answered' => 'in_progress',
    'completed' => 'completed', 'busy' => 'no_answer', 'no-answer' => 'no_answer',
    'failed' => 'failed', 'canceled' => 'failed'
  }.freeze

  def initialize(account:, call_sid:, call_status:, payload: {})
    @account = account
    @call_sid = call_sid
    @call_status = call_status
    @payload = payload || {}
  end

  def perform
    status = TWILIO_STATUS_MAP[@call_status.to_s]
    return if status.blank?

    call = Umi::Call.find_by(account_id: @account.id, provider: :twilio, provider_call_id: @call_sid)
    return if call.nil?

    Umi::Voice::CallStatus::Manager.new(call: call).process(status, duration: @payload['CallDuration'])
  end
end
