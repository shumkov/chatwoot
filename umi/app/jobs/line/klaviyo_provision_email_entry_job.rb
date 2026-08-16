# frozen_string_literal: true

class Umi::Line::KlaviyoProvisionEmailEntryJob < ApplicationJob
  queue_as :low

  retry_on Umi::Line::KlaviyoClient::TransientError, wait: :polynomially_longer, attempts: 10 do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_email_entry_failed outcome=retry_exhausted error=#{error.class.name}")
  end

  discard_on Umi::Line::KlaviyoClient::PermanentError do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_email_entry_failed outcome=permanent status=#{error.status || 'unknown'}")
  end

  discard_on Umi::Line::Config::MissingConfiguration do |_job, error|
    Rails.logger.error("[UMI-LINE] stage=klaviyo_email_entry_failed outcome=missing_configuration key=#{error.message}")
  end

  def perform(email:, email_entry_url:, fingerprint:)
    Umi::Line::KlaviyoClient.new.profile_import(
      email: email,
      properties: { 'umi_line_connect_url' => email_entry_url }
    )
    Rails.logger.info("[UMI-LINE] stage=klaviyo_email_entry outcome=success fingerprint=#{fingerprint}")
  end
end
