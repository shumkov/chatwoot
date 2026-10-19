# frozen_string_literal: true

class Umi::Shopify::ProductSource
  def self.verify!(source, facts)
    raise ArgumentError, 'Staff command is unavailable' unless staff_source?(source)

    command = source.content.to_s.match(%r{\A/send-product[ \t]+([^\s]+)[ \t]*\z})
    raise ArgumentError, 'Invalid product command' unless command

    ref = command[1]
    matches = if ref.match?(/\A[1-9]\d*\z/)
                facts['variant_id'].to_s == ref
              else
                url_matches?(ref, facts)
              end
    raise ArgumentError, 'Product does not match command' unless matches

    source.sender_id
  end

  def self.staff_source?(source)
    source.private? && source.outgoing? && source.sender.is_a?(User) &&
      source.account.account_users.exists?(user_id: source.sender_id) &&
      !source.content_attributes['shumabit_bridge'] && !source.content_attributes['deleted']
  end

  def self.url_matches?(ref, facts)
    uri = URI.parse(ref)
    query = URI.decode_www_form(uri.query.to_s)
    canonical = URI.parse(facts['canonical_url'] || facts.fetch('url'))
    valid_url?(uri) && valid_query?(query) &&
      uri.path.split('/').reject(&:empty?).last == canonical.path.split('/').last &&
      facts['variant_id'].to_s == query.to_h['variant'].to_s
  rescue URI::InvalidURIError
    false
  end

  def self.valid_query?(query)
    query.length <= 1 && query.all? { |key, value| key == 'variant' && value.match?(/\A[1-9]\d*\z/) }
  end

  def self.valid_url?(uri)
    uri.scheme == 'https' && uri.host == 'umi.store' && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? &&
      uri.path.match?(%r{\A/(?:th/)?products/[a-z0-9-]+/?\z})
  end
end
