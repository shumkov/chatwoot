# frozen_string_literal: true

# UMI patch: voice (calls) overlay. Rings agents' SIP softphones (Acrobits Groundwire)
# for inbound Twilio calls, injecting the Chatwoot contact name via Remote-Party-ID.
# App code: umi/app/{controllers/voice,services/voice,models/channel} (Umi:: namespace).
# remove-when: voice/calls is provided upstream, or extracted into a standalone engine.

# Prepend the voice extension onto the Twilio SMS channel + point the host call
# associations at the UMI-owned model (overriding the enterprise glue). Re-applied on reload.
Rails.application.reloader.to_prepare do
  Channel::TwilioSms.prepend(Umi::Channel::TwilioSms) unless Channel::TwilioSms.include?(Umi::Channel::TwilioSms)

  Message.class_eval do
    has_one :call, class_name: 'Umi::Call', foreign_key: :message_id, dependent: :nullify
  end
  [Account, Conversation, Inbox].each do |klass|
    klass.class_eval { has_many :calls, class_name: 'Umi::Call', dependent: :destroy_async }
  end
end

# Twilio inbound voice webhooks (append blocks are replayed on every route reload).
Rails.application.routes.append do
  namespace :umi do
    post 'voice/:phone/incoming', to: 'voice/webhooks#incoming'
    post 'voice/:phone/status', to: 'voice/webhooks#status'
    post 'voice/:phone/dial_status', to: 'voice/webhooks#dial_status'
    post 'voice/:phone/sip_status', to: 'voice/webhooks#sip_status'
    post 'voice/:phone/outbound_twiml', to: 'voice/webhooks#outbound_twiml'
    post 'voice/:phone/recording', to: 'voice/webhooks#recording'
    # Number onboarding: capture a voice-delivered OTP on a phoneless number (temporary Voice URL).
    post 'voice/:phone/otp_capture', to: 'voice/webhooks#otp_capture'
    # Tap-to-call link (mobile): GET confirms, POST places the call. Token identifies the contact.
    get 'voice/dial/:token', to: 'voice/mobile_dial#show'
    post 'voice/dial/:token', to: 'voice/mobile_dial#create'
    # "Call contact" macro webhook target (runs from the native mobile app too).
    post 'voice/macro_dial', to: 'voice/macro_dial#create'
  end
end

# Click-to-call: override the premium-gated enterprise `contacts/:id/call` (prepend so it wins).
Rails.application.routes.prepend do
  scope 'api/v1/accounts/:account_id', defaults: { format: :json } do
    post 'contacts/:contact_id/call', to: 'umi/voice/contact_calls#create'
  end
end
