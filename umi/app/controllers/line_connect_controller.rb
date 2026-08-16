# frozen_string_literal: true

class Umi::LineConnectController < ApplicationController
  prepend_view_path Rails.root.join('umi/app/views')
  before_action :ensure_enabled

  rescue_from Umi::Line::TokenService::InvalidEmail, with: :invalid_email
  rescue_from Umi::Line::TokenService::InvalidToken, Umi::Line::TokenService::Replay, with: :invalid_claim
  rescue_from Umi::Line::IdentityClient::Error, with: :line_error
  rescue_from Umi::Line::KlaviyoClient::Error, with: :klaviyo_error
  rescue_from Umi::Line::Config::MissingConfiguration, with: :configuration_error
  rescue_from ConnectionPool::TimeoutError, Redis::BaseError, with: :dependency_error

  def show
    @csp_nonce = SecureRandom.base64(18)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = content_security_policy
    render template: 'line_connect/show', locals: { nonce: @csp_nonce }
  end

  def token
    return head :no_content if request.options?

    return if reject_origin!(allow_public: params[:email_token].present?)

    result = if params[:email_token].present?
               Umi::Line::TokenService.exchange_email_entry(params[:email_token])
             else
               Umi::Line::TokenService.mint(params[:email])
             end
    render json: result
  end

  def bind
    return if reject_origin!(allow_public: true)
    return render json: { error: 'consent_required' }, status: :unprocessable_entity unless params[:consent] == true

    claim = Umi::Line::TokenService.peek(params[:token])
    identity = verified_identity(params[:id_token])

    Umi::Line::TokenService.consume(claim)

    consent_at = Time.current.utc.iso8601
    begin
      enqueue_binding(claim, identity, consent_at)
    rescue StandardError
      Umi::Line::TokenService.restore(claim)
      Rails.logger.error('[UMI-LINE] stage=bind_enqueue_failed outcome=claim_restored')
      raise
    end
    render json: { status: 'queued' }, status: :accepted
  end

  private

  def verified_identity(id_token)
    identity = Umi::Line::IdentityClient.new.verify_id_token(id_token)
    Umi::Line::IdentityClient.new.verify_friendship!(identity.fetch(:user_id))
    identity
  end

  def enqueue_binding(claim, identity, consent_at)
    email = claim.fetch('email')
    fingerprint = Umi::Line::TokenService.fingerprint(email)
    Umi::Line::KlaviyoBindJob.perform_later(
      email: email,
      line_user_id: identity.fetch(:user_id),
      line_display_name: identity[:display_name],
      consent_at: consent_at,
      fingerprint: fingerprint,
      verified_email: claim.fetch('verified_email', false)
    )
    Rails.logger.info("[UMI-LINE] stage=bind outcome=queued fingerprint=#{fingerprint}")
  end

  def reject_origin!(allow_public: false)
    origin = request.headers['Origin'].to_s
    allowed = Umi::Line::Config.allowed_origins
    allowed << URI.parse(Umi::Line::Config.public_base).origin if allow_public && Umi::Line::Config.public_base.present?
    return false if allowed.include?(origin)

    render json: { error: 'origin_not_allowed' }, status: :forbidden
    true
  end

  def ensure_enabled
    return if Umi::Line::Config.enabled?

    render json: { error: 'binding_disabled' }, status: :service_unavailable
  end

  def invalid_email(error)
    Rails.logger.info("[UMI-LINE] stage=mint outcome=invalid_email error=#{error.class.name}")
    render json: { error: 'invalid_email' }, status: :unprocessable_entity
  end

  def invalid_claim(error)
    Rails.logger.info("[UMI-LINE] stage=claim outcome=invalid_or_replayed error=#{error.class.name}")
    render json: { error: 'invalid_or_replayed_claim' }, status: :conflict
  end

  def line_error(error)
    status = error.kind == :transient ? :service_unavailable : :unprocessable_entity
    Rails.logger.warn("[UMI-LINE] stage=line_verify_failed outcome=#{error.kind}")
    render json: { error: 'line_verification_failed' }, status: status
  end

  def klaviyo_error(error)
    Rails.logger.error("[UMI-LINE] stage=klaviyo_mint_failed outcome=#{error.class.name} status=#{error.status || 'unknown'}")
    render json: { error: 'klaviyo_unavailable' }, status: :service_unavailable
  end

  def dependency_error(error)
    Rails.logger.error("[UMI-LINE] stage=redis_failure outcome=#{error.class.name}")
    render json: { error: 'binding_unavailable' }, status: :service_unavailable
  end

  def configuration_error(error)
    Rails.logger.error("[UMI-LINE] stage=config_missing outcome=#{error.message}")
    render json: { error: 'binding_unavailable' }, status: :service_unavailable
  end

  def content_security_policy
    sdk_origin = URI.parse(Umi::Line::Config.sdk_url).origin
    [
      "default-src 'none'",
      "script-src 'self' #{sdk_origin} 'nonce-#{@csp_nonce}'",
      "connect-src 'self' https://access.line.me https://api.line.me",
      'frame-src https://access.line.me https://liff.line.me',
      "img-src 'self' data:",
      "style-src 'self'"
    ].join('; ')
  end
end
