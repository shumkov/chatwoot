# frozen_string_literal: true

module Umi::Line::Config
  API_REVISION = '2026-07-15'
  TOKEN_TTL = 15.minutes
  EMAIL_ENTRY_TTL = 30.days
  ID_TOKEN_FRESHNESS = 10.minutes

  class MissingConfiguration < StandardError; end

  module_function

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_LINE_BINDING_ENABLED', false))
  end

  def public_base
    ENV.fetch('UMI_LINE_PUBLIC_BASE_URL', ENV.fetch('FRONTEND_URL', '')).to_s.chomp('/')
  end

  def liff_url
    return required('UMI_LINE_LIFF_URL') if Rails.env.production?

    ENV.fetch('UMI_LINE_LIFF_URL', "#{public_base}/line-connect").to_s.chomp('/')
  end

  def klaviyo_private_api_key
    required('UMI_KLAVIYO_PRIVATE_API_KEY')
  end

  def allowed_origins
    ENV.fetch('UMI_LINE_ALLOWED_ORIGINS', '').split(',').map(&:strip).reject(&:blank?)
  end

  def line_login_channel_id
    required('UMI_LINE_LOGIN_CHANNEL_ID')
  end

  def liff_id
    required('UMI_LINE_LIFF_ID')
  end

  def messaging_channel_access_token
    required('UMI_LINE_MESSAGING_CHANNEL_ACCESS_TOKEN')
  end

  def oa_add_friend_url
    required('UMI_LINE_OA_ADD_FRIEND_URL')
  end

  def consent_text
    required('UMI_LINE_CONSENT_TEXT')
  end

  def consent_text_version
    ENV.fetch('UMI_LINE_CONSENT_TEXT_VERSION', 'v1')
  end

  def consent_text_digest
    Digest::SHA256.hexdigest(consent_text)
  end

  def sdk_url
    ENV.fetch('UMI_LINE_LIFF_SDK_URL', 'https://static.line-scdn.net/liff/edge/versions/2.28.0/sdk.js')
  end

  def sdk_integrity
    required('UMI_LINE_LIFF_SDK_SRI')
  end

  def token_ttl
    ENV.fetch('UMI_LINE_BINDING_TOKEN_TTL', TOKEN_TTL.to_i).to_i.seconds
  end

  def email_entry_ttl
    ENV.fetch('UMI_LINE_EMAIL_ENTRY_TTL', EMAIL_ENTRY_TTL.to_i).to_i.seconds
  end

  def bind_url(token)
    "#{liff_url}?token=#{ERB::Util.url_encode(token)}"
  end

  def email_entry_url(token)
    "#{liff_url}?email_token=#{ERB::Util.url_encode(token)}"
  end

  def required(name)
    ENV.fetch(name)
  rescue KeyError
    raise MissingConfiguration, name
  end
end
