# frozen_string_literal: true

# Ensures the conversation attributes used by Meta ad attribution exist for an
# account with a Facebook Page or Instagram inbox.
class Umi::Meta::AdAttributeDefinitionSetup
  ATTRIBUTES = [
    ['meta_ad_id', 'Meta ad ID', 'The Meta ad this conversation started from. Joins to Ads Manager.'],
    ['meta_ad_ref', 'Meta ad ref', 'The per-ad reference string set when the ad was built. Blank unless someone set it.'],
    ['meta_ad_title', 'Meta ad', 'The ad name as it appears in Ads Manager.']
  ].freeze

  def initialize(account)
    @account = account
  end

  def ensure_definitions!
    return [] unless @account.inboxes.exists?(channel_type: %w[Channel::FacebookPage Channel::Instagram])

    ATTRIBUTES.map do |key, display_name, description|
      @account.custom_attribute_definitions.find_or_create_by!(
        attribute_key: key,
        attribute_model: 'conversation_attribute'
      ) do |definition|
        definition.attribute_display_name = display_name
        definition.attribute_display_type = 'text'
        definition.attribute_description = description
      end
    end
  end
end
