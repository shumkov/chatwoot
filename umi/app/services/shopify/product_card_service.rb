# frozen_string_literal: true

# The authenticated command endpoint verifies the staff source before calling this service.
class Umi::Shopify::ProductCardService
  FIELDS = %w[product_id title variant_id variant_title image_url canonical_url snapshot_at price].freeze

  def initialize(conversation:, facts:, source_id:, requested_by:)
    @conversation = conversation
    @facts = facts.stringify_keys.slice(*FIELDS)
    @source_id = source_id
    @requested_by = requested_by
  end

  def perform
    uri = canonical_uri
    token = Umi::Shopify::OrderLinkTokenService.mint(account_id: @conversation.account_id,
                                                     conversation_id: @conversation.id, contact_id: @conversation.contact_id)
    verify_claim!(token)
    uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s).to_h.except('umi_cw').to_a + [['umi_cw', token]])
    card = @facts.except('canonical_url').merge('version' => 1, 'url' => uri.to_s, 'source_id' => @source_id, 'requested_by' => @requested_by)
    @conversation.messages.create!(account_id: @conversation.account_id, inbox_id: @conversation.inbox_id,
                                   message_type: :outgoing, content_type: :text, private: false,
                                   content: summary, content_attributes: { 'umi_product_card' => card })
  rescue StandardError
    Umi::Shopify::OrderLinkTokenService.discard(token) if token
    raise
  end

  private

  def canonical_uri
    uri = URI.parse(@facts.fetch('canonical_url'))
    raise ArgumentError, 'Expected canonical UMI product URL' unless uri.scheme == 'https' && uri.host == 'umi.store' &&
                                                                     uri.path.match?(%r{\A/products/[a-z0-9-]+\z}) && uri.userinfo.nil?

    uri
  end

  def verify_claim!(token)
    claim = Umi::Shopify::OrderLinkTokenService.peek(token)
    raise ArgumentError, 'Attribution claim mismatch' unless claim.values_at('account_id', 'conversation_id', 'contact_id') ==
                                                             [@conversation.account_id, @conversation.id, @conversation.contact_id]
  end

  def summary
    parts = [@facts.fetch('title'), @facts['variant_title']]
    price = @facts['price']
    parts << "#{price.fetch('amount')} #{price.fetch('currency')} (#{price.fetch('market')})" if price
    parts << 'Product availability and price snapshot; checkout confirms final total.'
    parts.compact.join("\n")
  end
end
