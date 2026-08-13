require 'rails_helper'

# Business Discovery reaches the customers the messaging profile API refuses —
# in production that cohort held the influencers, twenty of them above 100,000
# followers, all displayed to agents as a bare lowercase handle. These examples
# pin what it writes, and every case where it must keep its hands off.
describe Umi::Fbig::BusinessDiscoveryEnrichment do
  let(:channel) { create(:channel_facebook_page) }
  let(:inbox) { channel.inbox }
  let(:account) { inbox.account }
  let(:enrichment) { Umi::Fbig::ProfileEnrichmentService.new(channel, run_id: 'run-1', apply: true) }
  let(:discovery) { described_class.new(channel, enrichment) }
  let(:lookup) { instance_double(Umi::Fbig::BusinessDiscoveryService) }
  let(:profile) do
    {
      'username' => 'marinaemmb', 'name' => 'Marina Balenciaga',
      'profile_picture_url' => 'https://scontent.example/marina.jpg',
      'followers_count' => 613_737, 'website' => 'https://lin.ee/marina',
      'biography' => 'Bangkok / Milan'
    }
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    channel.update!(instagram_id: 'ig-business-1')
    allow(Umi::Fbig::BusinessDiscoveryService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup).and_return(found(profile))
  end

  def found(profile)
    Umi::Fbig::BusinessDiscoveryService::Result.new(profile: profile, status: :found)
  end

  def answered(status)
    Umi::Fbig::BusinessDiscoveryService::Result.new(status: status)
  end

  def contact_with(name:, attrs: {}, source_id: 'ig-scope-1')
    contact = create(:contact, account: account, name: name, additional_attributes: attrs)
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: source_id)
    contact
  end

  describe 'finding a handle to ask about' do
    it 'uses the stored handle' do
      contact = contact_with(name: 'Someone', attrs: { 'social_instagram_user_name' => 'marinaemmb' })

      discovery.discover(contact)

      expect(lookup).to have_received(:lookup).with('marinaemmb')
    end

    # 117 of the 121 unreachable contacts in production have no stored handle:
    # the refresher resolved them through the participants endpoint, which for
    # Instagram answers with the handle and nothing else, and wrote it as the
    # name. That claim is the only handle they have.
    it 'falls back to a name this patch wrote and still owns' do
      contact = contact_with(name: 'marinaemmb', attrs: { 'umi_profile_name' => 'marinaemmb' })

      discovery.discover(contact)

      expect(lookup).to have_received(:lookup).with('marinaemmb')
    end

    it 'never treats a name an agent typed as a handle' do
      contact = contact_with(name: 'Khun Marina', attrs: { 'umi_profile_name' => 'marinaemmb' })

      expect(discovery.discover(contact).status).to eq(:skipped)
      expect(lookup).not_to have_received(:lookup)
    end

    it 'skips a contact whose name is not handle-shaped even if we wrote it' do
      contact = contact_with(name: 'Narongsak Sarika', attrs: { 'umi_profile_name' => 'Narongsak Sarika' })

      expect(discovery.discover(contact).status).to eq(:skipped)
      expect(lookup).not_to have_received(:lookup)
    end

    it 'refuses a contact whose erasure was requested' do
      contact = contact_with(name: 'marinaemmb',
                             attrs: { 'social_instagram_user_name' => 'marinaemmb', 'umi_profile_redacted' => true })

      expect(discovery.discover(contact).status).to eq(:redacted)
      expect(lookup).not_to have_received(:lookup)
    end
  end

  describe 'what it writes' do
    let(:contact) { contact_with(name: 'marinaemmb', attrs: { 'umi_profile_name' => 'marinaemmb' }) }

    before { allow(SafeFetch).to receive(:fetch) }

    it 'upgrades the handle-name to the real name' do
      expect(discovery.discover(contact).status).to eq(:updated)
      expect(contact.reload.name).to eq('Marina Balenciaga')
      expect(contact.additional_attributes['umi_profile_name']).to eq('Marina Balenciaga')
    end

    it 'stores the follower count, website and bio, and makes them visible' do
      discovery.discover(contact)

      expect(contact.reload.additional_attributes).to include(
        'social_instagram_follower_count' => 613_737,
        'social_instagram_website' => 'https://lin.ee/marina',
        'social_instagram_biography' => 'Bangkok / Milan',
        'social_instagram_user_name' => 'marinaemmb'
      )
      expect(contact.custom_attributes).to include(
        'instagram_followers' => 613_737,
        'instagram_audience' => '100K+',
        'instagram_website' => 'https://lin.ee/marina'
      )
    end

    it 'fetches the rescued profile picture' do
      discovery.discover(contact)

      expect(SafeFetch).to have_received(:fetch).with('https://scontent.example/marina.jpg', any_args)
    end

    # Meta hands out no email and no phone on either platform, and the one
    # address-shaped string it does return is a generated <psid>@facebook.com
    # that identifies nobody. Writing it would look like the lead funnel had
    # been fixed while making the contact permanently unmergeable.
    it 'never writes an email or a phone number' do
      allow(lookup).to receive(:lookup).and_return(found(profile.merge('email' => '2849628@facebook.com')))

      discovery.discover(contact)

      expect(contact.reload.email).to be_nil
      expect(contact.phone_number).to be_nil
      expect(contact.additional_attributes.values.map(&:to_s).join).not_to include('@facebook.com')
    end

    it 'refuses to rename a contact an agent has already named' do
      agent_named = contact_with(name: 'Marina (VIP)', attrs: { 'social_instagram_user_name' => 'marinaemmb' },
                                 source_id: 'ig-scope-2')

      discovery.discover(agent_named)

      expect(agent_named.reload.name).to eq('Marina (VIP)')
      expect(agent_named.custom_attributes['instagram_followers']).to eq(613_737)
    end

    it 'leaves an existing photo alone' do
      contact.avatar.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')

      discovery.discover(contact)

      expect(SafeFetch).not_to have_received(:fetch)
    end

    # Business Discovery carries no verification flag and no follow
    # relationship; a blank must not overwrite what the profile API told us.
    it 'keeps the flags only the messaging profile API can supply' do
      contact.update!(additional_attributes: contact.additional_attributes.merge(
        'social_instagram_is_verified_user' => true, 'social_instagram_is_user_follow_business' => true
      ))

      discovery.discover(contact)

      expect(contact.reload.additional_attributes).to include(
        'social_instagram_is_verified_user' => true, 'social_instagram_is_user_follow_business' => true
      )
      expect(contact.custom_attributes).to include('instagram_verified' => true, 'instagram_follows_us' => true)
    end
  end

  describe 'remembering what Meta answered' do
    let(:contact) { contact_with(name: 'someone.private', attrs: { 'umi_profile_name' => 'someone.private' }) }

    # 44 contacts are personal accounts, invisible to this endpoint forever. If
    # a definitive "no" were not remembered they would be re-asked every night
    # against a quota shared with live message delivery.
    it 'stamps a contact Meta says it cannot discover' do
      allow(lookup).to receive(:lookup).and_return(answered(:not_discoverable))

      expect(discovery.discover(contact).status).to eq(:not_discoverable)
      expect(contact.reload.additional_attributes).to have_key(Umi::Fbig::ProfileEnrichmentService::DISCOVERY_STAMP)
    end

    # A blip is not an answer; stamping it would hide the contact for a quarter.
    it 'leaves a transient failure unstamped so it is retried' do
      allow(lookup).to receive(:lookup).and_return(answered(:failed))

      expect(discovery.discover(contact).status).to eq(:failed)
      expect(contact.reload.additional_attributes).not_to have_key(Umi::Fbig::ProfileEnrichmentService::DISCOVERY_STAMP)
    end

    # The stamp drives the discovery queue only. Claiming a profile check would
    # push the contact to the back of the other pass's rotation for a full
    # cycle while its name and photo are still missing.
    it 'does not claim the contact was profile-checked' do
      allow(lookup).to receive(:lookup).and_return(answered(:not_discoverable))

      discovery.discover(contact)

      expect(contact.reload.additional_attributes).not_to have_key('umi_profile_checked_at')
    end

    it 'stamps a contact it did discover, so the quarterly refresh paces itself' do
      allow(SafeFetch).to receive(:fetch)
      discoverable = contact_with(name: 'marinaemmb', attrs: { 'umi_profile_name' => 'marinaemmb' }, source_id: 'ig-scope-3')

      discovery.discover(discoverable)

      expect(discoverable.reload.additional_attributes).to have_key(Umi::Fbig::ProfileEnrichmentService::DISCOVERY_STAMP)
    end
  end

  it 'lets an authentication error stand the whole run down' do
    contact = contact_with(name: 'marinaemmb', attrs: { 'umi_profile_name' => 'marinaemmb' })
    allow(lookup).to receive(:lookup).and_raise(Koala::Facebook::AuthenticationError.new(401, '{}'))

    expect { discovery.discover(contact) }.to raise_error(Koala::Facebook::AuthenticationError)
  end
end
