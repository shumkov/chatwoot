# frozen_string_literal: true

# Seeds the contact custom-attribute definitions the Instagram profile
# projection writes into.
#
# Without a definition row the value is invisible and unusable: the contact
# sidebar maps over definitions rather than over stored values, and an
# automation rule referencing an undefined key cannot be saved at all. So these
# rows are what make the write mean anything, not decoration.
#
# Scoped to accounts that actually own a Meta channel rather than assuming a
# single account, and written as raw SQL leaning on the existing unique index
# (attribute_key, attribute_model, account_id) so it is safe to re-run and does
# not depend on model validations that may change upstream.
class CreateUmiInstagramProfileAttributeDefinitions < ActiveRecord::Migration[7.0]
  # attribute_display_type enum: text 0, number 1, link 4, list 6, checkbox 7.
  # attribute_model enum: conversation_attribute 0, contact_attribute 1.
  CONTACT_ATTRIBUTE = 1
  ATTRIBUTES = [
    ['instagram_followers', 'Instagram followers', 1, 'Follower count Meta reported when we last read this profile.', '[]'],
    ['instagram_audience', 'Instagram audience', 6,
     'Follower count as a band. Use this to filter or automate — a number attribute has no greater-than.',
     '["Under 1K","1K-5K","5K-10K","10K-100K","100K+"]'],
    ['instagram_verified', 'Instagram verified', 7, 'Meta has verified this account.', '[]'],
    ['instagram_follows_us', 'Follows us on Instagram', 7, 'This customer follows the business account.', '[]'],
    ['instagram_followed_by_us', 'We follow them on Instagram', 7, 'The business account follows this customer.', '[]'],
    ['instagram_website', 'Instagram website', 4, 'The link in their Instagram bio. Often a LINE, Linktree or TikTok address.', '[]'],
    ['instagram_bio', 'Instagram bio', 0, 'Their Instagram bio text.', '[]']
  ].freeze

  def up
    account_ids = execute(<<~SQL.squish).to_a.pluck('account_id')
      SELECT DISTINCT account_id FROM inboxes
      WHERE channel_type IN ('Channel::FacebookPage', 'Channel::Instagram')
    SQL
    return if account_ids.empty?

    ATTRIBUTES.each do |key, display_name, display_type, description, values|
      account_ids.each do |account_id|
        execute(<<~SQL.squish)
          INSERT INTO custom_attribute_definitions
            (attribute_display_name, attribute_key, attribute_display_type, attribute_model,
             attribute_description, attribute_values, account_id, created_at, updated_at)
          VALUES
            (#{quote(display_name)}, #{quote(key)}, #{display_type}, #{CONTACT_ATTRIBUTE},
             #{quote(description)}, #{quote(values)}, #{quote(account_id)}, NOW(), NOW())
          ON CONFLICT (attribute_key, attribute_model, account_id) DO NOTHING
        SQL
      end
    end
  end

  def down
    # These rows share an account's custom-attribute namespace. A later owner
    # may have created a same-key definition with different meaning, so an
    # automatic down cannot distinguish patch-owned rows from user data.
    # Leave definitions in place; removing them requires an account-scoped,
    # operator-confirmed rollback.
  end
end
