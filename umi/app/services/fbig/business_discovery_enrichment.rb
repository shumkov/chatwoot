# frozen_string_literal: true

# Fills a contact's profile from Business Discovery — the public Instagram
# profile Meta will show any business about a Business or Creator account.
#
# This is the only route to the customers the messaging profile API refuses
# with error 230, and measured across every such contact in production it
# answered for 77 of 121 — the half where the influencers were: 43 with more
# than 10,000 followers, 20 above 100,000, the largest 613,737. All of them
# were showing to agents as a bare lowercase handle with no photo.
#
# Resolution lives here; the writing belongs to the profile enrichment
# service, whose rename claim, ledger, avatar uniqueness handling and erasure
# re-check are the whole safety story. A second copy of those gates is exactly
# the mistake this split avoids.
class Umi::Fbig::BusinessDiscoveryEnrichment
  Outcome = Umi::Fbig::ProfileEnrichmentService::Outcome
  Resolution = Umi::Fbig::ProfileEnrichmentService::Resolution
  STAMP = Umi::Fbig::ProfileEnrichmentService::DISCOVERY_STAMP

  def initialize(channel, enrichment)
    @channel = channel
    @enrichment = enrichment
  end

  def discover(contact)
    contact_inbox = @enrichment.sole_contact_inbox(contact)
    return Outcome.new(status: :skipped) if contact_inbox.nil?
    return Outcome.new(status: :redacted) if contact.additional_attributes['umi_profile_redacted']

    handle = discoverable_handle(contact)
    return Outcome.new(status: :skipped) if handle.nil?

    write(contact, contact_inbox, service.lookup(handle))
  rescue Koala::Facebook::AuthenticationError
    # A 401 is not about this contact. Let the caller stand the whole run down.
    raise
  rescue StandardError => e
    Umi::FbigTrace.log(:business_discovery_failed, contact: contact.id, reason: e.class.name)
    Outcome.new(status: :failed, error: e)
  end

  private

  def write(contact, contact_inbox, result)
    unless result.found?
      # Meta answering "no such discoverable account" is an answer, and the 44
      # personal accounts that can never be discovered would otherwise be
      # re-asked every night forever against a quota shared with live message
      # delivery. A transient failure is left unstamped so it is retried.
      @enrichment.stamp(contact, STAMP => Time.current.iso8601) if result.conclusive?
      return Outcome.new(status: result.conclusive? ? :not_discoverable : :failed)
    end

    @enrichment.apply_resolution(contact, contact_inbox, resolution_from(contact, contact_inbox, result.profile))
  end

  def resolution_from(contact, contact_inbox, profile)
    Resolution.new(
      name: (profile['name'].presence if @enrichment.rename_allowed?(contact, contact_inbox)),
      source: 'business_discovery',
      handle: profile['username'].presence,
      # Gap-fill only, matching the profile pass: an existing photo is never
      # replaced, whoever put it there.
      avatar_url: (profile['profile_picture_url'].presence unless contact.avatar.attached?),
      extra: { STAMP => Time.current.iso8601 }.merge(discovered_attributes(profile))
    )
  end

  # Business Discovery carries no verification flag and no follow relationship,
  # so those keys are never touched here — they come from the messaging profile
  # API, and writing a blank over them would lose data we already hold.
  def discovered_attributes(profile)
    {
      'social_instagram_follower_count' => profile['followers_count'],
      'social_instagram_website' => profile['website'],
      'social_instagram_biography' => profile['biography']
    }.compact_blank
  end

  # Business Discovery is keyed on the handle. Prefer the stored one; otherwise
  # take a name this patch wrote and still owns, which for an Instagram contact
  # resolved through the participants endpoint IS the handle — that endpoint
  # carries nothing else for this platform. An agent's own wording breaks the
  # equality and is never mistaken for a handle.
  def discoverable_handle(contact)
    stored = contact.additional_attributes['social_instagram_user_name'].presence
    return stored if stored

    claimed = contact.additional_attributes['umi_profile_name'].presence
    return nil unless claimed == contact.name

    claimed if claimed.match?(Umi::Fbig::BusinessDiscoveryService::HANDLE)
  end

  def service
    @service ||= Umi::Fbig::BusinessDiscoveryService.new(@channel)
  end
end
