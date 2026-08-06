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

  describe 'the first-pass placeholder gate' do
    it 'renames a placeholder that matches this contact_inbox source_id' do
      allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
      contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
      create(:conversation, account: account, inbox: inbox, contact: contact,
                            additional_attributes: { 'type' => 'instagram_direct_message' })

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
      create(:conversation, account: account, inbox: inbox, contact: contact,
                            additional_attributes: { 'type' => 'instagram_direct_message' })

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

    before { allow(SafeFetch).to receive(:fetch).and_yield(file) }

    it 'attaches when the contact has none' do
      allow(api).to receive(:get_object).and_return({ 'first_name' => 'Som', 'last_name' => 'Chai', 'profile_pic' => 'https://cdn/x.jpg' })
      contact = contact_with(name: 'John Doe', source_id: 'psid-1')

      service.enrich(contact)

      expect(contact.reload.avatar).to be_attached
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

  it 'falls back to participants when the profile API refuses' do
    allow(api).to receive(:get_object).and_raise(
      Koala::Facebook::ClientError.new(403, '', { 'type' => 'OAuthException', 'code' => 230, 'message' => 'consent required' })
    )
    allow(api).to receive(:get_connections).and_return(
      [{ 'participants' => { 'data' => [{ 'id' => 'ig-scope-4355', 'username' => 'commaand.th' }] } }]
    )
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    create(:conversation, account: account, inbox: inbox, contact: contact,
                          additional_attributes: { 'type' => 'instagram_direct_message' })

    service.enrich(contact)

    expect(contact.reload.name).to eq('commaand.th')
  end

  it 'records every write in the ledger, since Contact carries no audit trail' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    create(:conversation, account: account, inbox: inbox, contact: contact,
                          additional_attributes: { 'type' => 'instagram_direct_message' })

    service.enrich(contact)

    entry = Umi::ProfileLedgerEntry.find_by(contact_id: contact.id, attribute_name: 'name')
    expect(entry.old_value).to eq('Instagram user 4355')
    expect(entry.new_value).to eq('ploy.bkk')
    expect(entry.run_id).to eq('run-1')
  end

  it 'writes nothing without apply, but reports what it would change' do
    allow(api).to receive(:get_object).and_return({ 'username' => 'ploy.bkk' })
    contact = contact_with(name: 'Instagram user 4355', source_id: 'ig-scope-4355')
    create(:conversation, account: account, inbox: inbox, contact: contact,
                          additional_attributes: { 'type' => 'instagram_direct_message' })

    outcome = described_class.new(channel, run_id: 'dry', apply: false).enrich(contact)

    expect(outcome.status).to eq(:would_change)
    expect(outcome.name).to eq('ploy.bkk')
    expect(contact.reload.name).to eq('Instagram user 4355')
    expect(Umi::ProfileLedgerEntry.count).to eq(0)
  end
end
