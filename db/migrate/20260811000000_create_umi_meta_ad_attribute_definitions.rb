# frozen_string_literal: true

# Seeds the three conversation custom-attribute definitions the ad-attribution
# capture writes into.
#
# Without a definition row the value is invisible and unusable: the sidebar maps
# over definitions rather than stored values, and an automation rule referencing
# an undefined key cannot be saved at all. So these rows are what make the write
# mean anything, not decoration.
#
# Scoped to accounts that actually own a Meta channel rather than assuming a
# single account, and written as raw SQL leaning on the existing unique index
# (attribute_key, attribute_model, account_id) so it is safe to re-run and does
# not depend on model validations that may change upstream.
class CreateUmiMetaAdAttributeDefinitions < ActiveRecord::Migration[7.0]
  ATTRIBUTES = [
    ['meta_ad_id', 'Meta ad ID', 'The Meta ad this conversation started from. Joins to Ads Manager.'],
    ['meta_ad_ref', 'Meta ad ref', 'The per-ad reference string set when the ad was built. Blank unless someone set it.'],
    ['meta_ad_title', 'Meta ad', 'The ad name as it appears in Ads Manager.']
  ].freeze

  def up
    account_ids = execute(<<~SQL.squish).to_a.pluck('account_id')
      SELECT DISTINCT account_id FROM inboxes
      WHERE channel_type IN ('Channel::FacebookPage', 'Channel::Instagram')
    SQL
    return if account_ids.empty?

    ATTRIBUTES.each do |key, display_name, description|
      account_ids.each do |account_id|
        execute(<<~SQL.squish)
          INSERT INTO custom_attribute_definitions
            (attribute_display_name, attribute_key, attribute_display_type, attribute_model,
             attribute_description, attribute_values, account_id, created_at, updated_at)
          VALUES
            (#{quote(display_name)}, #{quote(key)}, 0, 0,
             #{quote(description)}, '[]', #{quote(account_id)}, NOW(), NOW())
          ON CONFLICT (attribute_key, attribute_model, account_id) DO NOTHING
        SQL
      end
    end
  end

  def down
    execute(<<~SQL.squish)
      DELETE FROM custom_attribute_definitions
      WHERE attribute_model = 0
        AND attribute_key IN (#{ATTRIBUTES.map { |key, _, _| quote(key) }.join(', ')})
    SQL
  end
end
