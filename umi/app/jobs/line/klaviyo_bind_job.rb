# frozen_string_literal: true

class Umi::Line::KlaviyoBindJob < ApplicationJob
  queue_as :low

  retry_on Umi::Line::KlaviyoClient::TransientError, wait: :polynomially_longer, attempts: 10 do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_bind_failed outcome=retry_exhausted error=#{error.class.name}")
  end

  discard_on Umi::Line::KlaviyoClient::PermanentError do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_bind_failed outcome=permanent status=#{error.status || 'unknown'}")
  end

  discard_on Umi::Line::Config::MissingConfiguration do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_bind_failed outcome=missing_configuration key=#{error.message}")
  end

  def perform(email:, line_user_id:, line_display_name:, consent_at:, fingerprint:, verified_email: false)
    Umi::Line::KlaviyoClient.new.profile_import(
      email: email,
      properties: {
        'line_user_id' => line_user_id,
        'line_display_name' => line_display_name,
        'line_bound_at' => consent_at,
        'line_consent_at' => consent_at,
        'line_marketing_consent' => true,
        'line_consent_source' => 'umi_line_connect',
        'line_consent_text_version' => Umi::Line::Config.consent_text_version,
        'line_consent_text_sha256' => Umi::Line::Config.consent_text_digest,
        'line_binding_verified' => verified_email
      }
    )
    Rails.logger.info("[UMI-LINE] stage=bound outcome=success fingerprint=#{fingerprint}")
  end
end
