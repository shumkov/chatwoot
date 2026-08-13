# frozen_string_literal: true

# Moves the Instagram profile facts Meta hands us out of the invisible bucket
# and into the one the product reads.
#
# Chatwoot stores Meta's profile reply in contacts.additional_attributes, which
# nothing renders, filters or automates on. Only custom_attributes with a
# matching CustomAttributeDefinition appear in the sidebar, in a segment, or in
# an automation rule — so the definition rows below are what make the values
# mean anything.
#
# The audience band exists because a `number` attribute offers only equal_to /
# not_equal_to in both filter UIs (dashboard/helper/automationHelper.js maps
# number -> OPERATOR_TYPES_1, and components-next/filter/operators.js does the
# same). "Followers over 10,000" is therefore not authorable against the raw
# count; against the band it is. The count is still stored, for the exact
# figure and for sorting.
class Umi::Meta::InstagramProfileAttributes
  FOLLOWERS = 'instagram_followers'
  AUDIENCE = 'instagram_audience'
  VERIFIED = 'instagram_verified'
  FOLLOWS_US = 'instagram_follows_us'
  FOLLOWED_BY_US = 'instagram_followed_by_us'
  WEBSITE = 'instagram_website'
  BIO = 'instagram_bio'

  KEYS = [FOLLOWERS, AUDIENCE, VERIFIED, FOLLOWS_US, FOLLOWED_BY_US, WEBSITE, BIO].freeze

  # Ordered smallest-first; the label of the first band whose floor the count
  # reaches wins when read in reverse.
  BANDS = [
    [0, 'Under 1K'],
    [1_000, '1K-5K'],
    [5_000, '5K-10K'],
    [10_000, '10K-100K'],
    [100_000, '100K+']
  ].freeze

  BAND_VALUES = BANDS.map(&:last).freeze

  # key, display name, display type, description, values
  DEFINITIONS = [
    [FOLLOWERS, 'Instagram followers', 'number', 'Follower count Meta reported when we last read this profile.', []],
    [AUDIENCE, 'Instagram audience', 'list', 'Follower count as a band. Use this to filter or automate — a number attribute has no greater-than.',
     BAND_VALUES],
    [VERIFIED, 'Instagram verified', 'checkbox', 'Meta has verified this account.', []],
    [FOLLOWS_US, 'Follows us on Instagram', 'checkbox', 'This customer follows the business account.', []],
    [FOLLOWED_BY_US, 'We follow them on Instagram', 'checkbox', 'The business account follows this customer.', []],
    [WEBSITE, 'Instagram website', 'link', 'The link in their Instagram bio. Often a LINE, Linktree or TikTok address.', []],
    [BIO, 'Instagram bio', 'text', 'Their Instagram bio text.', []]
  ].freeze

  # Where each value is read from in additional_attributes. Meta returns these
  # unrequested on every Instagram profile fetch Chatwoot already makes, and
  # Instagram::WebhooksBaseService stores them under this prefix.
  SOURCES = {
    FOLLOWERS => 'social_instagram_follower_count',
    VERIFIED => 'social_instagram_is_verified_user',
    FOLLOWS_US => 'social_instagram_is_user_follow_business',
    FOLLOWED_BY_US => 'social_instagram_is_business_follow_user',
    WEBSITE => 'social_instagram_website',
    BIO => 'social_instagram_biography'
  }.freeze

  def self.band_for(count)
    return nil if count.blank?

    count = Integer(count, exception: false)
    return nil if count.nil? || count.negative?

    BANDS.reverse_each { |floor, label| return label if count >= floor }
    nil
  end

  def self.ensure_definitions!(account)
    return [] unless account.inboxes.exists?(channel_type: %w[Channel::FacebookPage Channel::Instagram])

    DEFINITIONS.map do |key, display_name, display_type, description, values|
      account.custom_attribute_definitions.find_or_create_by!(
        attribute_key: key,
        attribute_model: 'contact_attribute'
      ) do |definition|
        definition.attribute_display_name = display_name
        definition.attribute_display_type = display_type
        definition.attribute_description = description
        definition.attribute_values = values
      end
    end
  end

  # Returns the custom_attributes patch for a contact, or {} when Meta has told
  # us nothing about them. Values are read straight from the stored profile, so
  # this costs no API call.
  def self.projection_for(contact)
    stored = contact.additional_attributes || {}
    patch = SOURCES.each_with_object({}) do |(key, source), acc|
      value = stored[source]
      acc[key] = value unless value.nil? || value == ''
    end

    band = band_for(stored[SOURCES[FOLLOWERS]])
    patch[AUDIENCE] = band if band
    patch
  end

  # Written as a SQL merge rather than contact.update!: this runs beside
  # Avatar::AvatarFromUrlJob, which rewrites whole jsonb columns from a
  # job-start snapshot, and beside the Shopify sync, which owns other keys in
  # this same column. The redaction tombstone is re-checked here in SQL because
  # a nightly run walks contacts over minutes and an erasure can land in
  # between — a Ruby-side check would have read the contact before it.
  def self.project!(contact)
    patch = projection_for(contact)
    return false if patch.empty?

    updated = Contact.connection.exec_update(
      Contact.sanitize_sql_array(
        ["UPDATE contacts SET custom_attributes = COALESCE(custom_attributes, '{}'::jsonb) || ?::jsonb " \
         "WHERE id = ? AND COALESCE(additional_attributes->>'umi_profile_redacted', 'false') != 'true'",
         patch.to_json, contact.id]
      )
    )
    updated.positive?
  end

  # One-time sweep for the contacts whose values arrived before there was
  # anywhere for them to go. Makes no Meta call, so it costs nothing against
  # the app quota that live message delivery shares.
  def self.project_all!(account, dry_run: false)
    counts = Hash.new(0)
    account.contacts.where('additional_attributes ?| array[:keys]', keys: SOURCES.values).find_each do |contact|
      counts[:eligible] += 1
      projection_for(contact).each_key { |key| counts[key.to_sym] += 1 }
      counts[:written] += 1 if !dry_run && project!(contact)
    end
    counts
  end
end
