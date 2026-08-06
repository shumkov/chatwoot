require 'rails_helper'

# The write gates are the whole safety story here: this rewrites the names of
# real customers in a live support inbox, on a contact model that carries no
# audit trail. Each example below pins one way it must refuse.
describe Umi::Fbig::ProfileEnrichmentService do
  # The channel factory builds its own inbox; creating another would leave the
  # service looking at a different one than the contacts are attached to.
  # Lazy so the Meta subscription stub below is in place before it is built.
  let(:channel) { create(:channel_facebook_page) }
  let(:inbox) { channel.inbox }
  let(:account) { inbox.account }
  let(:api) { double }
  let(:service) { described_class.new(channel, run_id: 'run-1', apply: true) }

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
    allow(api).to receive(:get_object).and_return({})
  end

  def contact_with(name:, source_id:, attrs: {})
    contact = create(:contact, account: account, name: name, additional_attributes: attrs)
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: source_id)
    contact
  end

  # The conversation factory mints its own contact_inbox unless handed one,
  # which would make the contact look like an ambiguous merged record.
  def instagram_conversation_for(contact)
    create(:conversation, account: account, inbox: inbox, contact: contact,
                          contact_inbox: contact.contact_inboxes.find_by(inbox_id: inbox.id),
                          additional_attributes: { 'type' => 'instagram_direct_message' })
  end

  describe 'the first-pass placeholder gate' do
    it 'renames a placeholder that matches this contact_inbox source_id' do
      allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
      contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
      instagram_conversation_for(contact)

      service.enrich(contact)

      expect(contact.reload.name).to eq('ploy.bkk')
      expect(contact.additional_attributes['umi_profile_name']).to eq('ploy.bkk')
    end

    # A contact can own several contact_inboxes across both platforms; a
    # blanket LIKE would stamp one Meta identity's handle onto another.
    it 'refuses a placeholder whose digits belong to a different source_id' do
      allow(api).to receive(:get_object).and_return({ 'username' => 'someone.else' })
      contact = contact_with(name: 'Instagram user 9999', source_id: 'ig-scope-4355')

      service.enrich(contact)

      expect(contact.reload.name).to eq('Instagram user 9999')
    end

    it 'refuses a name an agent wrote' do
      allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
      contact = contact_with(name: 'Ploy — VIP, nut allergy', source_id: 'ig-scope-4355')

      service.enrich(contact)

      expect(contact.reload.name).to eq('Ploy — VIP, nut allergy')
    end
  end

  describe 'the provenance gate on later cycles' do
    it 'refreshes a name it wrote when Meta now returns a real display name' do
      allow(api).to receive(:get_object).and_return({ 'name' => 'Ploy Suwan', 'username' => 'ploy.bkk' })
      contact = contact_with(name: 'ploy.bkk', source_id: 'ig-scope-4355',
                             attrs: { 'umi_profile_name' => 'ploy.bkk' })
      instagram_conversation_for(contact)

      service.enrich(contact)

      expect(contact.reload.name).to eq('Ploy Suwan')
    end

    # Without this the refresher overwrites an agent's edit on every cycle,
    # forever — the failure the value-equality gate exists to prevent.
    it 'never touches a contact again once an agent edits the name we wrote' do
      allow(api).to receive(:get_object).and_return({ 'name' => 'Ploy Suwan', 'username' => 'ploy.bkk' })
      contact = contact_with(name: 'Ploy (returns customer)', source_id: 'ig-scope-4355',
                             attrs: { 'umi_profile_name' => 'ploy.bkk' })

      service.enrich(contact)

      expect(contact.reload.name).to eq('Ploy (returns customer)')
    end
  end

  # jsonb_set with create_if_missing only creates the FINAL key, so pathing
  # into '{social_profiles,instagram}' silently does nothing when the contact
  # has no social_profiles object — which is every contact this targets. The
  # sidebar renders the Instagram link from social_profiles, so the handle
  # would just never appear.
  it 'writes the handle into social_profiles even when the contact has none yet' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    instagram_conversation_for(contact)

    service.enrich(contact)

    expect(contact.reload.additional_attributes['social_profiles']).to eq({ 'instagram' => 'ploy.bkk' })
    expect(contact.additional_attributes['social_instagram_user_name']).to eq('ploy.bkk')
  end

  it 'preserves unrelated social profiles when merging the handle' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355',
                           attrs: { 'social_profiles' => { 'twitter' => 'ploytweets' } })
    instagram_conversation_for(contact)

    service.enrich(contact)

    expect(contact.reload.additional_attributes['social_profiles'])
      .to eq({ 'twitter' => 'ploytweets', 'instagram' => 'ploy.bkk' })
  end

  # A run walks up to `cap` contacts over minutes, so an erasure can land
  # between a contact being selected and being written.
  it 'refuses to write to a contact erased after it was selected' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    # Bypasses callbacks deliberately: simulates an erasure landing in another
    # process after this contact was selected.
    Contact.where(id: contact.id)
           .update_all("additional_attributes = additional_attributes || '{\"umi_profile_redacted\": true}'::jsonb") # rubocop:disable Rails/SkipsModelValidations

    service.enrich(contact)

    expect(contact.reload.name).to eq('Instagram user 4355')
    expect(contact.additional_attributes).not_to have_key('umi_profile_name')
    expect(contact.additional_attributes).not_to have_key('social_instagram_user_name')
    expect(Umi::ProfileLedgerEntry.where(contact_id: contact.id)).to be_empty
  end

  # ContactMergeAction deep-merges additional_attributes while the base
  # contact's name wins, so a stamp can land on a name it does not describe.
  it 'refuses a contact carrying a stamp transplanted by a merge' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Somchai Prasert', source_id: 'ig-scope-4355',
                           attrs: { 'umi_profile_name' => 'ploy.bkk' })

    service.enrich(contact)

    expect(contact.reload.name).to eq('Somchai Prasert')
  end

  it 'never re-enriches a contact whose erasure was requested' do
    contact = contact_with(name: 'Redacted customer', source_id: 'ig-scope-4355',
                           attrs: { 'umi_profile_redacted' => true })

    expect(service.enrich(contact).status).to eq(:redacted)
    expect(api).not_to have_received(:get_object)
    expect(contact.reload.name).to eq('Redacted customer')
  end

  describe 'avatars' do
    # Stands in for the upload SafeFetch yields.
    let(:file) do
      Struct.new(:tempfile, :original_filename, :content_type)
            .new(Rails.root.join('spec/assets/avatar.png').open, 'a.png', 'image/png')
    end

    # A realistic Meta CDN URL, not a short placeholder: ApplicationRecord caps
    # :string columns at 255, so a short URL in the ledger hides the fact that
    # every real attach would raise RecordInvalid.
    let(:profile_pic) do
      "https://scontent-bkk1-2.cdninstagram.com/v/t51.2885-19/#{'a' * 300}.jpg?stp=dst-jpg&amp;_nc_ht=scontent.cdninstagram.com&amp;oe=68F1A2B3"
    end

    before { allow(SafeFetch).to receive(:fetch).and_yield(file) }

    it 'attaches when the contact has none, and names the contact from the Facebook profile' do
      allow(api).to receive(:get_object).and_return({ 'first_name' => 'Som', 'last_name' => 'Chai', 'profile_pic' => profile_pic })
      contact = contact_with(name: 'John Doe', source_id: 'psid-1')

      service.enrich(contact)

      expect(contact.reload.avatar).to be_attached
      expect(contact.name).to eq('Som Chai')
      expect(SafeFetch).to have_received(:fetch).with(
        profile_pic,
        hash_including(max_bytes: 15.megabytes,
                       allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES,
                       allowed_content_type_prefixes: [])
      )
      entry = Umi::ProfileLedgerEntry.find_by(contact_id: contact.id, attribute_name: 'avatar')
      expect(entry.new_value).to eq(profile_pic)
    end

    it 'builds a Facebook name from whichever components Meta returns' do
      allow(api).to receive(:get_object).and_return({ 'first_name' => 'Som' })
      contact = contact_with(name: 'John Doe', source_id: 'psid-2')

      service.enrich(contact)

      expect(contact.reload.name).to eq('Som')
    end

    # Gap-fill only. Meta's profile_pic is a signed URL that differs on every
    # fetch, so replacing would re-download the whole population every cycle
    # and destroy agent-uploaded avatars.
    it 'never replaces an avatar that already exists' do
      allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk', 'profile_pic' => 'https://cdn/x.jpg' })
      contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
      contact.avatar.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'existing.png', content_type: 'image/png')

      service.enrich(contact)

      expect(contact.reload.avatar.filename.to_s).to eq('existing.png')
      expect(SafeFetch).not_to have_received(:fetch)
    end
  end

  # The local rung returns a handle, never a display name. Reading it on a later
  # cycle renamed a real name Meta had already given us back down to the handle
  # — silent, one-way, and scored healthy by the name-shape census.
  it 'does not downgrade a real name to the handle on a later cycle' do
    allow(api).to receive(:get_object).and_return({ 'name' => 'Ploy Suwan', 'username' => 'ploy.bkk',
                                                    'profile_pic' => 'https://cdn/x.jpg' })
    allow(SafeFetch).to receive(:fetch).and_yield(
      Struct.new(:tempfile, :original_filename, :content_type)
            .new(Rails.root.join('spec/assets/avatar.png').open, 'a.png', 'image/png')
    )
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    instagram_conversation_for(contact)

    service.enrich(contact)
    expect(contact.reload.name).to eq('Ploy Suwan')

    # Second cycle: avatar and handle are now stored, so the service takes its
    # local short-circuit and makes no Graph call at all.
    service.enrich(contact.reload)

    expect(contact.reload.name).to eq('Ploy Suwan')
  end

  # ContactMergeAction moves every contact_inbox onto the surviving contact, so
  # "which Meta identity is this" becomes genuinely ambiguous — picking one
  # would write another customer's handle onto the record.
  it 'refuses a merged contact that owns several contact_inboxes in the inbox' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'someone.else' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'ig-scope-9999')

    expect(service.enrich(contact).status).to eq(:skipped)
    expect(contact.reload.name).to eq('Instagram user 4355')
  end

  # The 7 Haikunator contacts are the cohort the live-path fix stops minting;
  # this is the only way the existing ones ever get repaired.
  it 'renames a Haikunator-shaped contact' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'lingering-sun-586', source_id: 'ig-scope-4355')

    service.enrich(contact)

    expect(contact.reload.name).to eq('ploy.bkk')
  end

  # The over-match direction is the one that damages agent data.
  it 'refuses a real name that superficially resembles the Haikunator shape' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Anna-Marie Chen-1', source_id: 'ig-scope-4355')

    service.enrich(contact)

    expect(contact.reload.name).to eq('Anna-Marie Chen-1')
  end

  it 'stamps checked_at always, but last_success_at only when something resolved' do
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    allow(api).to receive(:get_object).and_return({})
    allow(api).to receive(:get_connections).and_return([])

    service.enrich(contact)

    attrs = contact.reload.additional_attributes
    expect(attrs).to have_key('umi_profile_checked_at')
    expect(attrs).not_to have_key('umi_profile_last_success_at')
  end

  it 'falls back to participants when the profile API refuses' do
    allow(api).to receive(:get_object).and_raise(
      Koala::Facebook::ClientError.new(403, '', { 'type' => 'OAuthException', 'code' => 230, 'message' => 'consent required' })
    )
    allow(api).to receive(:get_connections).and_return(
      [{ 'participants' => { 'data' => [{ 'id' => 'ig-scope-4355', 'username' => 'commaand.th' }] } }]
    )
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    instagram_conversation_for(contact)

    service.enrich(contact)

    expect(contact.reload.name).to eq('commaand.th')
  end

  it 'records every write in the ledger, since Contact carries no audit trail' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    instagram_conversation_for(contact)

    service.enrich(contact)

    entry = Umi::ProfileLedgerEntry.find_by(contact_id: contact.id, attribute_name: 'name')
    expect(entry.old_value).to eq('Instagram user 4355')
    expect(entry.new_value).to eq('ploy.bkk')
    expect(entry.run_id).to eq('run-1')
  end

  it 'writes nothing without apply, but reports what it would change' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    instagram_conversation_for(contact)

    outcome = described_class.new(channel, run_id: 'dry', apply: false).enrich(contact)

    expect(outcome.status).to eq(:would_change)
    expect(outcome.name).to eq('ploy.bkk')
    expect(contact.reload.name).to eq('Instagram user 4355')
    expect(Umi::ProfileLedgerEntry.count).to eq(0)
  end
end
