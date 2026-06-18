# frozen_string_literal: true

# Voice (calls) extensions for the Twilio SMS channel, prepended via prepend_mod_with.
module Umi::Channel::TwilioSms
  def umi_voice_enabled?
    voice_enabled?
  end

  # SIP domain the agents' softphones register to. Global for the pilot; per-channel later.
  def umi_sip_domain
    ENV.fetch('UMI_VOICE_SIP_DOMAIN', nil)
  end

  # Twilio REST client for placing outbound calls (account SID + auth token).
  def umi_voice_client
    ::Twilio::REST::Client.new(account_sid, auth_token)
  end

  # Recording is opt-in (consent/legal); off by default.
  def umi_recording_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_VOICE_RECORDING', false))
  end
end
