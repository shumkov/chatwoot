# frozen_string_literal: true

# Twilio inbound voice webhooks for the UMI calls feature. Public endpoints (no session),
# authenticated by the Twilio request signature.
class Umi::Voice::WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  before_action :set_channel
  before_action :validate_twilio_signature

  # Logs the call (contact → conversation → voice_call message, screen-pop) and rings the
  # on-duty agents' SIP softphones, injecting the contact name via Remote-Party-ID.
  def incoming
    resolver = Umi::Voice::InboundResolver.new(channel: @channel, params: params)
    call = Umi::Voice::InboundCallBuilder.perform!(channel: @channel, from_number: resolver.caller_number, call_sid: params[:CallSid])
    xml = Umi::Voice::Twiml::DialBuilder.new(
      domain: @channel.umi_sip_domain,
      agent_usernames: ring_targets(resolver),
      caller_number: resolver.caller_number,
      caller_name: call.contact&.name,
      dial_action_url: "#{Umi::Voice.public_base}/umi/voice/#{params[:phone]}/dial_status",
      recording_status_url: recording_status_url
    ).to_xml
    render xml: xml
  end

  # Twilio per-call status callback (in-progress / completed / failed …).
  def status
    Umi::Voice::StatusUpdateService.new(
      account: @channel.account, call_sid: params[:CallSid],
      call_status: params[:CallStatus], payload: params.to_unsafe_h
    ).perform
    head :no_content
  end

  # <Dial action> result — the outcome of ringing the agents.
  def dial_status
    call = Umi::Call.find_by(account_id: @channel.account_id, provider: :twilio, provider_call_id: params[:CallSid])
    if call
      manager = Umi::Voice::CallStatus::Manager.new(call: call)
      case params[:DialCallStatus]
      when 'answered', 'completed' then manager.process('completed', duration: params[:DialCallDuration])
      when 'no-answer', 'busy', 'failed', 'canceled' then manager.process('no_answer')
      end
    end
    head :no_content
  end

  # TwiML the agent's leg fetches on answer (click-to-call): bridge to the contact.
  def outbound_twiml
    response = ::Twilio::TwiML::VoiceResponse.new
    response.dial(**outbound_dial_options) { |dial| dial.number(params[:to].to_s) }
    render xml: response.to_s
  end

  # Twilio recording-status callback (download + attach handled asynchronously).
  def recording
    Umi::Voice::RecordingStatusService.new(account: @channel.account, payload: params.to_unsafe_h).perform
    head :no_content
  end

  # Number-onboarding helper: answer the call and record + transcribe the caller. A
  # phoneless Twilio number can't receive a normal verification call, so when a provider
  # (e.g. Meta/WhatsApp Cloud API) delivers an OTP by voice, point the number's Voice URL
  # here during onboarding to capture the spoken code, then revert it to `incoming`.
  def otp_capture
    response = ::Twilio::TwiML::VoiceResponse.new
    response.record(transcribe: true, max_length: 30, timeout: 10, play_beep: false)
    render xml: response.to_s
  end

  private

  def set_channel
    digits = params[:phone].to_s.gsub(/\D/, '')
    @channel = ::Channel::TwilioSms.find_by(phone_number: "+#{digits}")
    head :not_found if @channel.nil? || !@channel.umi_voice_enabled?
  end

  def validate_twilio_signature
    return if Umi::Voice.skip_signature_validation?

    validator = ::Twilio::Security::RequestValidator.new(@channel.auth_token)
    valid = validator.validate(Umi::Voice.webhook_url(request), request.request_parameters, request.headers['X-Twilio-Signature'])
    return if valid

    head :forbidden
  end

  # Allow an explicit override (e.g. the pilot's `agent1`) via env; otherwise ring the inbox agents.
  def ring_targets(resolver)
    override = ENV.fetch('UMI_VOICE_AGENTS', nil)
    return override.split(',').map(&:strip) if override.present?

    resolver.agent_usernames
  end

  def recording_status_url
    return unless @channel.umi_recording_enabled?

    "#{Umi::Voice.public_base}/umi/voice/#{params[:phone]}/recording"
  end

  def outbound_dial_options
    opts = { caller_id: @channel.phone_number }
    return opts unless @channel.umi_recording_enabled?

    opts.merge(record: 'record-from-answer-dual',
               recording_status_callback: "#{Umi::Voice.public_base}/umi/voice/#{params[:phone]}/recording",
               recording_status_callback_event: 'completed')
  end
end
