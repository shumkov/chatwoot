# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Meta::AdAttributeDefinitionSetup do
  let!(:account) { create(:account) }

  it 'does not provision definitions for an account without a Meta inbox' do
    expect { described_class.new(account).ensure_definitions! }
      .not_to change(CustomAttributeDefinition, :count)
  end

  it 'provisions the three conversation definitions idempotently for a Meta inbox' do
    channel = create(:channel_instagram_fb_page, account: account)
    create(:inbox, account: account, channel: channel)

    expect { described_class.new(account).ensure_definitions! }
      .to change { account.custom_attribute_definitions.where(attribute_model: 'conversation_attribute').count }.from(0).to(3)

    expect { described_class.new(account).ensure_definitions! }
      .not_to(change { account.custom_attribute_definitions.where(attribute_model: 'conversation_attribute').count })
  end
end
