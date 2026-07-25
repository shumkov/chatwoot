require 'rails_helper'

# rubocop:disable Rails/SkipsModelValidations
RSpec.describe Umi::Fbig::ProfileStateSnapshot do
  let(:account) { create(:account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '991234') }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '1000', instagram_id: '2000')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Instagram user 1234',
      additional_attributes: {
        'owner_note' => 'keep',
        'social_profiles' => { 'twitter' => 'kept' }
      }
    )
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    contact_inbox
  end

  it 'serializes and parses the exact 27-field PII-free row contract' do
    artifact = described_class.capture(inbox)
    parsed = described_class.parse(artifact.bytes)
    row = parsed.rows.fetch(0)

    expect(parsed).to have_attributes(account_id: account.id, inbox_id: inbox.id)
    expect(row.values.size).to eq(27)
    expect(row.name_state).to eq('exact_instagram_placeholder')
    expect(row.username_state).to eq('absent')
    expect(row.avatar_state).to eq('absent')
    expect(artifact.bytes).not_to include('991234', 'Instagram user 1234', 'owner_note', 'twitter')
    expect(artifact.sha256).to eq(Digest::SHA256.hexdigest(artifact.bytes))
  end

  it 'seals and reloads fixed production prestate and poststate artifacts' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      prestate = described_class.capture_and_seal!(
        inbox,
        directory: directory,
        basename: 'fbig-profile-production-prestate-v1.tsv',
        expected_uid: Process.uid
      )
      loaded = described_class.load(
        path: Pathname.new(directory).join('fbig-profile-production-prestate-v1.tsv').to_s,
        checksum_path: Pathname.new(directory).join('fbig-profile-production-prestate-v1.tsv.sha256').to_s,
        expected_uid: Process.uid
      )

      expect(loaded.sha256).to eq(prestate.sha256)
      expect(loaded.rows.map(&:key)).to eq(prestate.rows.map(&:key))

      poststate = described_class.capture_and_seal!(
        inbox,
        directory: directory,
        basename: 'fbig-profile-production-poststate-v1.tsv',
        expected_uid: Process.uid
      )
      expect(poststate.sha256).to eq(Digest::SHA256.hexdigest(poststate.bytes))
    end
  end

  it 'checks the writer lease around each bounded capture batch and before sealing' do
    checkpoints = 0
    renewer = lambda do
      checkpoints += 1
      checkpoints < 3
    end

    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      expect do
        described_class.capture_and_seal!(
          inbox,
          directory: directory,
          basename: 'fbig-profile-production-prestate-v1.tsv',
          expected_uid: Process.uid,
          renewer: renewer
        )
      end.to raise_error(described_class::LeaseLost)

      expect(Pathname.new(directory).children).to be_empty
    end
  end

  it 'accepts only counter-attributed fill-only transitions and blocks protected drift' do
    before = described_class.capture(inbox)
    attributes = contact.additional_attributes.deep_dup
    attributes['social_profiles']['instagram'] = 'profile_name'
    attributes['social_instagram_user_name'] = 'profile_name'
    attributes['social_instagram_follower_count'] = 0
    contact.update_columns(name: 'Profile Name', additional_attributes: attributes)
    after = described_class.capture(inbox)

    comparison = Umi::Fbig::ProfileStateComparator.compare(
      before: before,
      after: after,
      applied_counters: {
        name: 1,
        username: 2,
        optional: 1,
        avatar: 0
      }
    )

    expect(comparison).to be_success
    expect(comparison.eligible_counts).to eq(name: 1, username: 2, optional: 1, avatar: 0)

    contact.update_columns(email: 'protected@example.com')
    protected_after = described_class.capture(inbox)
    protected = Umi::Fbig::ProfileStateComparator.compare(
      before: after,
      after: protected_after,
      applied_counters: { name: 0, username: 0, optional: 0, avatar: 0 }
    )

    expect(protected).not_to be_success
    expect(protected.protected_changes).to eq(1)
  end
end
# rubocop:enable Rails/SkipsModelValidations
