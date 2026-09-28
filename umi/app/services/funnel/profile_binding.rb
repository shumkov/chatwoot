# frozen_string_literal: true

class Umi::Funnel::ProfileBinding
  def initialize(contact:, profile_id: nil, actor: nil, reason: nil)
    @contact = contact
    @profile_id = profile_id.to_s
    @actor = actor
    @reason = reason.to_s.strip
  end

  def perform
    raise ArgumentError, 'Klaviyo account mismatch' unless @contact.account_id == Integer(ENV.fetch('UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'))
    raise ArgumentError, 'Actor must belong to account' unless @contact.account.users.exists?(id: @actor.id)
    raise ArgumentError, 'Reason must contain 1-1000 characters' unless @reason.length.between?(1, 1000)

    profile = Umi::Funnel::KlaviyoClient.new.profile(@profile_id)
    raise ArgumentError, 'Unexpected profile response' unless profile['id'] == @profile_id

    with_binding_lock { bind!(profile) }
    @contact
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def resolve
    raise ArgumentError, 'Klaviyo account mismatch' unless @contact.account_id == Integer(ENV.fetch('UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'))

    @contact.reload
    return @contact if @contact.additional_attributes['umi_klaviyo_profile_id'].present? || @contact.additional_attributes['umi_profile_redacted']

    identifiers = self.class.identifiers(@contact)
    return @contact if identifiers.empty?

    profile = find_profile(identifiers)
    return @contact unless profile

    @profile_id = profile.fetch('id')
    with_binding_lock do
      next if @contact.additional_attributes['umi_klaviyo_profile_id'].present?
      next unless yield(@profile_id)
      raise ArgumentError, 'Contact identifiers changed' unless identifiers == self.class.identifiers(@contact)
      raise ArgumentError, 'Duplicate contact identity' if duplicate_identity?(identifiers)

      bind!(profile)
    end
    @contact
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.identifiers(contact)
    email = contact.email.to_s.strip.downcase.presence
    phone = contact.phone_number.to_s.gsub(/[\s().-]/, '')
    { 'email' => email, 'phone_number' => (phone if phone.match?(Umi::Shopify::CustomerContactMapper::E164)) }.compact
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def self.matches?(contact, profile, profile_id)
    return false unless profile.is_a?(Hash) && profile['id'] == profile_id && profile['attributes'].is_a?(Hash)

    attributes = profile['attributes']
    local_email = contact.email.to_s.strip.downcase.presence
    remote_email = attributes['email'].to_s.strip.downcase.presence
    emails = [local_email, remote_email]
    phones = [contact.phone_number, attributes['phone_number']].map do |value|
      phone = value.to_s.gsub(/[\s().-]/, '')
      phone if phone.match?(Umi::Shopify::CustomerContactMapper::E164)
    end
    shared = [emails, phones].select { |pair| pair.all?(&:present?) }
    shared.any? && shared.all? { |left, right| left == right }
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private

  def with_binding_lock(&)
    Contact.transaction do
      # Serialize binding the same provider identity without locking the account's other work.
      key = Contact.connection.quote("umi-klaviyo:#{@contact.account_id}:#{@profile_id}")
      Contact.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{key}, 0))")
      @contact.with_lock(&)
    end
  end

  def find_profile(identifiers)
    page = Umi::Funnel::KlaviyoClient.new.profiles(identifiers)
    profiles = page.fetch('data')
    return if profiles.empty? && page.dig('links', 'next').blank?
    raise ArgumentError, 'Ambiguous Klaviyo identity' unless profiles.one? && page.dig('links', 'next').blank?

    profiles.first
  end

  def duplicate_identity?(identifiers)
    others = Contact.where(account_id: @contact.account_id).where.not(id: @contact.id)
                    .where("COALESCE(additional_attributes ->> 'umi_profile_redacted', 'false') != 'true'")
    email = others.where('LOWER(TRIM(email)) = ?', identifiers['email']) if identifiers['email']
    phone = others.where("regexp_replace(phone_number, '[[:space:]().-]', '', 'g') = ?", identifiers['phone_number']) if identifiers['phone_number']
    (email && phone ? email.or(phone) : email || phone).exists?
  end

  def bind!(profile)
    raise ArgumentError, 'Contact is redacted' if @contact.additional_attributes['umi_profile_redacted']
    raise ArgumentError, 'Klaviyo identity conflict' unless self.class.matches?(@contact, profile, @profile_id)

    others = Contact.where(account_id: @contact.account_id).where.not(id: @contact.id)
                    .where("additional_attributes ->> 'umi_klaviyo_profile_id' = ?", @profile_id)
    raise ArgumentError, 'Profile belongs to another contact' if others.exists?

    metadata = { 'verified_at' => Time.current.utc.iso8601 }
    metadata.merge!(@actor ? { 'actor_id' => @actor.id, 'reason' => @reason } : { 'source' => 'exact_identifier_match' })
    @contact.update!(additional_attributes: @contact.additional_attributes.merge(
      'umi_klaviyo_profile_id' => @profile_id,
      'umi_klaviyo_binding' => metadata
    ))
  end
end
