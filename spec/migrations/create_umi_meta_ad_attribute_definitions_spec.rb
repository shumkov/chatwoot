# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260811000000_create_umi_meta_ad_attribute_definitions')

RSpec.describe CreateUmiMetaAdAttributeDefinitions do
  let!(:account) { create(:account) }
  let(:migration) { described_class.new }

  it 'does nothing for accounts without a Meta inbox' do
    expect { migration.up }.not_to change(CustomAttributeDefinition, :count)
  end

  it 'is safe to rerun for an account with a Meta inbox' do
    channel = create(:channel_instagram_fb_page, account: account)
    create(:inbox, account: account, channel: channel)

    expect { migration.up }.to change { account.custom_attribute_definitions.count }.from(0).to(3)
    expect { migration.up }.not_to(change { account.custom_attribute_definitions.count })
  end

  it 'does not delete a same-key definition during down' do
    definition = create(
      :custom_attribute_definition,
      account: account,
      attribute_key: 'meta_ad_id',
      attribute_model: 'conversation_attribute'
    )

    migration.down

    expect(CustomAttributeDefinition.exists?(definition.id)).to be(true)
  end
end
