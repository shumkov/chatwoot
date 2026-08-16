# frozen_string_literal: true

module Umi::Line::TokenService
  PURPOSE = 'umi:line:binding'
  CLAIM_PREFIX = 'UMI_LINE_BINDING_CLAIM::'
  EMAIL_ENTRY_PREFIX = 'UMI_LINE_EMAIL_ENTRY::'

  class Error < StandardError; end
  class InvalidEmail < Error; end
  class InvalidToken < Error; end
  class Replay < Error; end

  module_function

  # The cleanup covers both claim records when queueing the companion email link fails.
  # rubocop:disable Metrics/MethodLength
  def mint(email, provision_email: true, verified_email: false)
    canonical_email = normalize_email(email)
    nonce = SecureRandom.urlsafe_base64(32)
    raw_claim = { 'email' => canonical_email, 'nonce' => nonce, 'verified_email' => verified_email }.to_json
    Redis::Alfred.set(claim_key(nonce), raw_claim, ex: Umi::Line::Config.token_ttl.to_i)

    email_entry_url = nil
    if provision_email
      email_nonce = SecureRandom.urlsafe_base64(32)
      email_entry_url = Umi::Line::Config.email_entry_url(email_nonce)
      Redis::Alfred.set(email_entry_key(email_nonce), canonical_email, ex: Umi::Line::Config.email_entry_ttl.to_i)
      Umi::Line::KlaviyoProvisionEmailEntryJob.perform_later(
        email: canonical_email,
        email_entry_url: email_entry_url,
        fingerprint: fingerprint(canonical_email)
      )
    end

    response = { url: Umi::Line::Config.bind_url(signed_token(nonce)) }
    response[:email_entry_url] = email_entry_url if email_entry_url
    response
  rescue StandardError
    Redis::Alfred.delete(claim_key(nonce)) if nonce
    Redis::Alfred.delete(email_entry_key(email_nonce)) if email_nonce
    raise
  end
  # rubocop:enable Metrics/MethodLength

  def exchange_email_entry(email_token)
    email_nonce = email_token.to_s
    email = Redis::Alfred.get(email_entry_key(email_nonce))
    raise InvalidToken if email.blank?
    raise Replay unless consume!(email_entry_key(email_nonce)) == email

    mint(email, provision_email: false, verified_email: true)
  end

  def peek(token)
    payload = verifier.verify(token.to_s, purpose: PURPOSE)
    nonce = payload.fetch('nonce')
    raw_claim = Redis::Alfred.get(claim_key(nonce))
    raise Replay if raw_claim.blank?

    claim = JSON.parse(raw_claim)
    raise InvalidToken unless claim['nonce'] == nonce && claim['email'].present?

    claim.merge('raw' => raw_claim)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, JSON::ParserError
    raise InvalidToken
  end

  def consume(claim)
    key = claim_key(claim.fetch('nonce'))
    raise Replay unless consume!(key) == claim.fetch('raw')

    true
  end

  def restore(claim)
    Redis::Alfred.set(claim_key(claim.fetch('nonce')), claim.fetch('raw'), nx: true, ex: Umi::Line::Config.token_ttl.to_i)
  end

  def consume!(key)
    Redis::Alfred.with do |conn|
      conn.redis.getdel("#{conn.full_namespace}:#{key}")
    end
  end
  private_class_method :consume!

  def fingerprint(email)
    Digest::SHA256.hexdigest(email.to_s)[0, 16]
  end

  def normalize_email(email)
    value = email.to_s.strip.downcase
    valid = value.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    raise InvalidEmail unless valid

    value
  end

  def signed_token(nonce)
    verifier.generate({ 'v' => 1, 'nonce' => nonce }, purpose: PURPOSE, expires_in: Umi::Line::Config.token_ttl)
  end

  def verifier
    ActiveSupport::MessageVerifier.new(
      Rails.application.secret_key_base,
      url_safe: true,
      serializer: JSON,
      digest: 'SHA256'
    )
  end

  def claim_key(nonce)
    "#{CLAIM_PREFIX}#{nonce}"
  end

  def email_entry_key(nonce)
    "#{EMAIL_ENTRY_PREFIX}#{nonce}"
  end
end
