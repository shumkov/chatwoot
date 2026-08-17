# frozen_string_literal: true

module Umi::Shopify::OrderLinkTokenService
  PURPOSE = 'umi:shopify:order-link'
  CLAIM_PREFIX = 'UMI_SHOPIFY_ORDER_LINK_CLAIM::'
  TOKEN_TTL = 30.days

  class Error < StandardError; end
  class InvalidToken < Error; end
  class Replay < Error; end

  module_function

  def mint(account_id:, conversation_id:, contact_id:)
    nonce = SecureRandom.urlsafe_base64(32)
    claim = {
      'v' => 1,
      'account_id' => account_id.to_i,
      'conversation_id' => conversation_id.to_i,
      'contact_id' => contact_id.to_i,
      'nonce' => nonce
    }
    raw_claim = claim.to_json
    Redis::Alfred.set(claim_key(nonce), raw_claim, ex: TOKEN_TTL.to_i)

    verifier.generate(claim, purpose: PURPOSE, expires_in: TOKEN_TTL)
  rescue StandardError
    Redis::Alfred.delete(claim_key(nonce)) if nonce
    raise
  end

  def peek(token)
    payload = verifier.verify(token.to_s, purpose: PURPOSE)
    nonce = payload.fetch('nonce')
    raw_claim = Redis::Alfred.get(claim_key(nonce))
    raise Replay if raw_claim.blank?

    claim = JSON.parse(raw_claim)
    raise InvalidToken unless claim == payload && claim['v'] == 1

    claim.merge('raw' => raw_claim)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, JSON::ParserError
    raise InvalidToken
  end

  def consume(claim)
    # redis-namespace does not map GETDEL in the supported version, so use the
    # underlying connection while preserving its full namespace explicitly.
    consumed = Redis::Alfred.with do |conn|
      conn.redis.getdel("#{conn.full_namespace}:#{claim_key(claim.fetch('nonce'))}")
    end
    raise Replay unless consumed == claim.fetch('raw')

    true
  end

  def restore(claim)
    Redis::Alfred.set(claim_key(claim.fetch('nonce')), claim.fetch('raw'), nx: true, ex: TOKEN_TTL.to_i)
  end

  def discard(token)
    payload = verifier.verify(token.to_s, purpose: PURPOSE)
    Redis::Alfred.delete(claim_key(payload.fetch('nonce')))
    true
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError
    false
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
end
