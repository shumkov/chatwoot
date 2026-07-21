# frozen_string_literal: true

# UMI patch: maps one Shopify REST customer payload to Chatwoot contact
# attributes. Pure — no Shopify or DB access — so the normalization rules are
# unit-testable in isolation.
#
# Rules:
# - a customer with neither a valid email nor a valid phone maps to no
#   attributes (no channel could ever match it; it would sit invisible in the
#   unresolved-contact set);
# - email is downcased — the unique contacts index is on raw email, so casing is
#   identity;
# - phone must already be strict E.164; Thai local formats ("0xx…") are NOT
#   guessed into "+66…" because a wrong guess poisons caller-ID matching. Falls
#   back to the default address phone when the customer-level one is unusable;
# - contact_type / location / country_code are set explicitly because the bulk
#   import path skips the before_save Contacts::SyncAttributes denormalization.
class Umi::Shopify::CustomerContactMapper
  E164 = /\A\+[1-9]\d{1,14}\z/
  # additional_attributes keys owned by the sync (kept current on enrich, and the
  # set the compliance handler strips on redact). city/country are shared with
  # other writers (e.g. ip_lookup) and are only ever filled when blank.
  SHOPIFY_KEYS = %w[
    shopify_customer_id shopify_orders_count shopify_total_spent shopify_currency
    shopify_tags shopify_accepts_email_marketing shopify_accepts_sms_marketing
  ].freeze

  Result = Struct.new(:attributes, :updated_at, :dropped_email, :dropped_phone, keyword_init: true)

  def self.map(customer)
    new(customer).map
  end

  def initialize(customer)
    @customer = customer.with_indifferent_access
  end

  def map
    email = normalized_email
    phone = normalized_phone
    attributes = build_attributes(email, phone) if email.present? || phone.present?

    Result.new(
      attributes: attributes,
      updated_at: parsed_updated_at,
      dropped_email: raw_email.present? && email.blank?,
      dropped_phone: raw_phones.any?(&:present?) && phone.blank?
    )
  end

  private

  def build_attributes(email, phone)
    {
      name: name(email, phone),
      email: email,
      phone_number: phone,
      contact_type: 'customer',
      location: address[:city].presence,
      country_code: address[:country_code].presence,
      additional_attributes: additional_attributes
    }
  end

  def raw_email
    @customer[:email].to_s.strip
  end

  def normalized_email
    email = raw_email.downcase
    email.match?(Devise.email_regexp) ? email : nil
  end

  def raw_phones
    [@customer[:phone].to_s.strip, address[:phone].to_s.strip]
  end

  def normalized_phone
    raw_phones.find { |phone| phone.match?(E164) }
  end

  def name(email, phone)
    full_name = [@customer[:first_name], @customer[:last_name]].map { |part| part.to_s.strip }.reject(&:empty?).join(' ')
    return full_name if full_name.present?
    return email.split('@').first if email.present?

    phone
  end

  # shopify_* keys keep their nils: a nil means "absent/cleared in Shopify" and
  # the enrich merge deletes the stored key (a compact here would silently
  # freeze stale tags/consent forever). Create paths compact before insert.
  def additional_attributes
    {
      'shopify_customer_id' => @customer[:id],
      'shopify_orders_count' => @customer[:orders_count],
      'shopify_total_spent' => @customer[:total_spent],
      'shopify_currency' => @customer[:currency],
      'shopify_tags' => @customer[:tags].to_s.presence,
      'shopify_accepts_email_marketing' => consent(:email_marketing_consent),
      'shopify_accepts_sms_marketing' => consent(:sms_marketing_consent),
      'city' => address[:city].presence,
      'country' => address[:country_code].presence
    }
  end

  def consent(key)
    state = @customer.dig(key, :state)
    return nil if state.blank?

    state == 'subscribed'
  end

  def address
    @address ||= (@customer[:default_address] || {}).with_indifferent_access
  end

  def parsed_updated_at
    Time.zone.parse(@customer[:updated_at].to_s)
  rescue ArgumentError
    nil
  end
end
