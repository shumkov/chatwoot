# frozen_string_literal: true

# Helpers + config for the UMI fork's voice (calls) feature, built on Twilio + SIP softphones.
module Umi::Voice
  module_function

  def skip_signature_validation?
    # The bypass is only ever honored in development/test — never in production.
    return false unless Rails.env.local?

    ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_VOICE_SKIP_SIGNATURE', false))
  end

  def public_base
    ENV.fetch('FRONTEND_URL', '').to_s.chomp('/')
  end

  # Signed tap-to-call link (e.g. a contact custom attribute the mobile app renders as a link):
  # the token identifies the contact; Chatwoot then places + logs the call. Tamper-proof so the
  # link can't be retargeted at another contact.
  def dial_url(contact)
    "#{public_base}/umi/voice/dial/#{dial_token(contact.id)}"
  end

  def dial_token(contact_id)
    dial_verifier.generate(contact_id)
  end

  def verify_dial_token(token)
    dial_verifier.verify(token.to_s)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def dial_verifier
    ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base, url_safe: true, serializer: JSON, digest: 'SHA256')
  end

  # Webhook URL for the "Call contact" macro. Chatwoot's send_webhook_event action takes only a URL
  # (no headers, and it posts unsigned), so the URL itself must carry the auth. The token is a
  # purpose-scoped HMAC of secret_key_base — leaking it never exposes the master key; it is redacted
  # from Rails logs by the `token` param filter; and at worst it lets someone ring a conversation's
  # existing assignee + dial its existing contact (a nuisance, no data access). Rotate via the HMAC
  # purpose string in #macro_secret.
  def macro_dial_url
    "#{public_base}/umi/voice/macro_dial?token=#{macro_secret}"
  end

  def valid_macro_token?(token)
    ActiveSupport::SecurityUtils.secure_compare(token.to_s, macro_secret)
  end

  def macro_secret
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, 'umi:voice:macro')
  end

  # The exact public URL Twilio signed, reconstructed from the configured base so signature
  # validation works behind a reverse proxy (request.url would report the internal host).
  def webhook_url(request)
    base = public_base
    return request.original_url if base.blank?

    "#{base}#{request.fullpath}"
  end
end
