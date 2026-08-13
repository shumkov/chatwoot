require 'rails_helper'

# The whole point of this class is that a value in additional_attributes is
# invisible: no sidebar, no filter, no automation rule, no AI assistant. These
# examples pin the copy across, and pin what it must refuse to touch.
describe Umi::Meta::InstagramProfileAttributes do
  let(:account) { create(:account) }

  def contact_with(attrs)
    create(:contact, account: account, additional_attributes: attrs)
  end

  describe 'the audience band' do
    # The band exists because a `number` custom attribute offers only
    # equal_to / not_equal_to in both filter UIs, so "over 10,000 followers"
    # cannot be expressed against the raw count at all. Boundaries are pinned
    # because a contact landing in the wrong band is a wrong routing decision.
    {
      0 => 'Under 1K', 999 => 'Under 1K',
      1_000 => '1K-5K', 4_999 => '1K-5K',
      5_000 => '5K-10K', 9_999 => '5K-10K',
      10_000 => '10K-100K', 99_999 => '10K-100K',
      100_000 => '100K+', 613_737 => '100K+'
    }.each do |count, band|
      it "puts #{count} followers in #{band}" do
        expect(described_class.band_for(count)).to eq(band)
      end
    end

    it 'reads a count Meta sent as a string' do
      expect(described_class.band_for('12000')).to eq('10K-100K')
    end

    it 'has no band for a missing or nonsense count' do
      expect([described_class.band_for(nil), described_class.band_for(''), described_class.band_for('many')]).to all(be_nil)
    end
  end

  describe 'projecting stored values' do
    it 'copies every field Meta already gave us into the visible bucket' do
      contact = contact_with(
        'social_instagram_follower_count' => 24_500,
        'social_instagram_is_verified_user' => true,
        'social_instagram_is_user_follow_business' => true,
        'social_instagram_is_business_follow_user' => false,
        'social_instagram_website' => 'https://lin.ee/abc',
        'social_instagram_biography' => 'Bangkok based'
      )

      expect(described_class.project!(contact)).to be(true)
      expect(contact.reload.custom_attributes).to eq(
        'instagram_followers' => 24_500,
        'instagram_audience' => '10K-100K',
        'instagram_verified' => true,
        'instagram_follows_us' => true,
        'instagram_followed_by_us' => false,
        'instagram_website' => 'https://lin.ee/abc',
        'instagram_bio' => 'Bangkok based'
      )
    end

    # false is a meaningful answer — "does not follow us" — and dropping it
    # would leave the checkbox indistinguishable from "never asked".
    it 'keeps a false flag rather than treating it as absent' do
      contact = contact_with('social_instagram_is_user_follow_business' => false)

      described_class.project!(contact)

      expect(contact.reload.custom_attributes).to eq('instagram_follows_us' => false)
    end

    # The Shopify sync owns other keys in this same column; a read-modify-write
    # or a whole-column assignment would silently drop them.
    it 'leaves custom attributes another integration owns untouched' do
      contact = contact_with('social_instagram_follower_count' => 2_000)
      contact.update!(custom_attributes: { 'shopify_orders' => 4 })

      described_class.project!(contact)

      expect(contact.reload.custom_attributes).to include('shopify_orders' => 4, 'instagram_followers' => 2_000)
    end

    it 'writes nothing for a contact Meta has told us nothing about' do
      contact = contact_with('shopify_customer_id' => '123')

      expect(described_class.project!(contact)).to be(false)
      expect(contact.reload.custom_attributes).to eq({})
    end

    # An erasure must not be undone by a later pass re-deriving the same facts
    # from data the erasure could not reach.
    it 'refuses a contact whose erasure was requested' do
      contact = contact_with('social_instagram_follower_count' => 9_000, 'umi_profile_redacted' => true)

      expect(described_class.project!(contact)).to be(false)
      expect(contact.reload.custom_attributes).to eq({})
    end

    # Meta returns <psid>@facebook.com in one Messenger reply. It is the user
    # id with a domain stuck on it, it receives no mail, and writing it would
    # make the contact permanently unmergeable — while looking like the lead
    # funnel had been fixed. Merging is the only identity resolution that works
    # in this system, so this is the expensive mistake to prevent.
    it 'never writes an email address' do
      contact = contact_with(
        'social_instagram_follower_count' => 9_000,
        'email' => '28496282546630721@facebook.com'
      )

      expect { described_class.project!(contact) }.not_to(change { contact.reload.email })
      expect(contact.reload.email).to be_nil
      expect(contact.custom_attributes.values.join).not_to include('@facebook.com')
    end
  end

  describe 'definitions' do
    # The channel factory builds its own inbox and subscribes to Meta on
    # create; the account under test has to be the one it built.
    let(:channel) { create(:channel_facebook_page) }
    let(:account) { channel.inbox.account }

    before { stub_request(:post, /graph\.facebook\.com/) }

    # Without a definition row the value is invisible and unusable: the sidebar
    # maps over definitions rather than stored values, and an automation rule
    # referencing an undefined key cannot be saved at all.
    it 'creates one contact attribute per field, typed for what it is' do
      described_class.ensure_definitions!(account)

      definitions = account.custom_attribute_definitions.where(attribute_model: 'contact_attribute').index_by(&:attribute_key)
      expect(definitions.keys).to match_array(described_class::KEYS)
      expect(definitions['instagram_followers'].attribute_display_type).to eq('number')
      expect(definitions['instagram_audience'].attribute_display_type).to eq('list')
      expect(definitions['instagram_audience'].attribute_values).to eq(described_class::BAND_VALUES)
      expect(definitions['instagram_verified'].attribute_display_type).to eq('checkbox')
      expect(definitions['instagram_website'].attribute_display_type).to eq('link')
    end

    it 'can be run again without duplicating or raising' do
      described_class.ensure_definitions!(account)

      expect { described_class.ensure_definitions!(account) }
        .not_to(change { account.custom_attribute_definitions.count })
    end

    it 'provisions nothing for an account with no Meta inbox' do
      other = create(:account)

      expect(described_class.ensure_definitions!(other)).to eq([])
    end
  end

  describe 'the one-time sweep' do
    let!(:covered) { contact_with('social_instagram_follower_count' => 150_000) }
    let!(:untouched) { create(:contact, account: account) }

    it 'projects the contacts whose values arrived before there was anywhere to put them' do
      counts = described_class.project_all!(account)

      expect(counts[:written]).to eq(1)
      expect(covered.reload.custom_attributes['instagram_audience']).to eq('100K+')
      expect(untouched.reload.custom_attributes).to eq({})
    end

    it 'writes nothing on a dry run' do
      counts = described_class.project_all!(account, dry_run: true)

      expect(counts[:eligible]).to eq(1)
      expect(counts[:written]).to eq(0)
      expect(covered.reload.custom_attributes).to eq({})
    end
  end
end
