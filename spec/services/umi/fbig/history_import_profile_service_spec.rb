require 'rails_helper'

RSpec.describe Umi::Fbig::HistoryImportProfileService do
  subject(:service) { described_class.new(sleeper: ->(_delay) {}) }

  let(:source_id) { '17841400001234567' }
  let(:profile_url) { 'https://cdn.example/profile.png' }
  let(:image_file) { Tempfile.new(['history-profile', '.png'], binmode: true) }
  let(:image_result) do
    SafeFetch::Result.new(tempfile: image_file, filename: 'profile.png', content_type: 'image/png')
  end

  after do
    image_file.close!
  end

  describe '#plan' do
    # rubocop:disable RSpec/ExampleLength
    it 'repairs only the exact Instagram placeholder and fills empty Instagram profile fields' do
      contact = create(
        :contact,
        name: "Instagram user #{source_id.last(4)}",
        additional_attributes: {
          'keep' => { 'nested' => true },
          'social_profiles' => { 'facebook' => 'preserved', 'instagram' => '' },
          'social_instagram_user_name' => '',
          'social_instagram_follower_count' => 0,
          'social_instagram_is_verified_user' => false
        }
      )
      profile = {
        'name' => 'Profile Name',
        'username' => 'profile_username',
        'profile_pic' => profile_url,
        'follower_count' => 99,
        'is_user_follow_business' => false,
        'is_business_follow_user' => true,
        'is_verified_user' => true
      }

      plan = service.plan(
        platform: :instagram,
        source_id: source_id,
        profile: profile,
        participant_name: 'Participant Name',
        observed_sender_username: 'sender_username',
        contact: contact
      )

      expect(plan.contact_attributes[:name]).to eq('Profile Name')
      expect(plan.contact_attributes[:additional_attributes]).to eq(
        'keep' => { 'nested' => true },
        'social_profiles' => {
          'facebook' => 'preserved',
          'instagram' => 'profile_username'
        },
        'social_instagram_user_name' => 'profile_username',
        'social_instagram_follower_count' => 0,
        'social_instagram_is_user_follow_business' => false,
        'social_instagram_is_business_follow_user' => true,
        'social_instagram_is_verified_user' => false
      )
      expect(plan.avatar_candidate.url).to eq(profile_url)
      expect(contact.reload).to have_attributes(
        name: "Instagram user #{source_id.last(4)}",
        additional_attributes: {
          'keep' => { 'nested' => true },
          'social_profiles' => { 'facebook' => 'preserved', 'instagram' => '' },
          'social_instagram_user_name' => '',
          'social_instagram_follower_count' => 0,
          'social_instagram_is_verified_user' => false
        }
      )
    end
    # rubocop:enable RSpec/ExampleLength

    it 'falls back to participant name and observed incoming sender username for Instagram' do
      plan = service.plan(
        platform: :instagram,
        source_id: source_id,
        profile: {},
        participant_name: 'Participant Name',
        observed_sender_username: 'observed_username'
      )

      expect(plan.contact_attributes).to eq(
        name: 'Participant Name',
        additional_attributes: {
          'social_profiles' => { 'instagram' => 'observed_username' },
          'social_instagram_user_name' => 'observed_username'
        }
      )
    end

    it 'combines Messenger profile names but does not generically rewrite Facebook placeholders' do
      contact = create(:contact, name: "Facebook user #{source_id.last(4)}")

      plan = service.plan(
        platform: :messenger,
        source_id: source_id,
        profile: { 'first_name' => '  Mary ', 'last_name' => ' Jones ' },
        participant_name: 'Participant Name',
        contact: contact
      )

      expect(plan.name_candidate).to eq('Mary Jones')
      expect(plan.contact_attributes[:name]).to eq("Facebook user #{source_id.last(4)}")
      expect(plan.contact_attributes[:additional_attributes]).to eq({})
    end

    it 'preserves custom, near-match, different-suffix, and no-candidate Instagram names' do
      names_and_profiles = [
        ['Agent Renamed', { 'name' => 'Meta Name' }],
        ["Instagram user #{source_id.last(4)} ", { 'name' => 'Meta Name' }],
        ['Instagram user 9999', { 'name' => 'Meta Name' }],
        ["Instagram user #{source_id.last(4)}", { 'name' => ' ' }]
      ]

      names_and_profiles.each do |name, profile|
        contact = create(:contact, name: name)
        plan = service.plan(
          platform: :instagram,
          source_id: source_id,
          profile: profile,
          participant_name: nil,
          contact: contact
        )

        expect(plan.contact_attributes[:name]).to eq(name)
      end
    end

    it 'projects scalar attributes for a new Contact without creating one or writing anything' do
      profile = {
        'name' => 'New Contact',
        'username' => 'new_contact',
        'profile_pic' => profile_url
      }
      counts = [Contact.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count]

      plan = service.plan(
        platform: :instagram,
        source_id: source_id,
        profile: profile,
        participant_name: 'Participant'
      )

      expect(plan.contact_attributes).to eq(
        name: 'New Contact',
        additional_attributes: {
          'social_profiles' => { 'instagram' => 'new_contact' },
          'social_instagram_user_name' => 'new_contact'
        }
      )
      expect(plan.avatar_candidate.url).to eq(profile_url)
      expect([Contact.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count]).to eq(counts)
    end
  end

  describe '#apply!' do
    it 'uses the same projection and directly updates scalar columns without callbacks, events, or jobs' do
      contact = create(
        :contact,
        name: "Instagram user #{source_id.last(4)}",
        additional_attributes: { 'unrelated' => { 'value' => 1 } }
      )
      plan = service.plan(
        platform: :instagram,
        source_id: source_id,
        profile: { 'name' => 'Meta Name', 'username' => 'meta_username' },
        participant_name: 'Participant Name',
        contact: contact
      )
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      allow(contact).to receive(:save!).and_call_original
      allow(contact).to receive(:update!).and_call_original
      clear_enqueued_jobs
      original_updated_at = contact.reload.updated_at

      result = service.apply!(contact: contact, plan: plan)

      expect(result).to have_attributes(status: :updated, changed: true)
      expect(contact.reload).to have_attributes(
        name: plan.contact_attributes[:name],
        additional_attributes: plan.contact_attributes[:additional_attributes]
      )
      expect(contact).not_to have_received(:save!)
      expect(contact).not_to have_received(:update!)
      expect(contact.reload.updated_at).to eq(original_updated_at)
      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
      expect(enqueued_jobs).to be_empty
    end

    it 'preserves an agent edit made after planning when it rechecks under the write lock' do
      contact = create(:contact, name: "Instagram user #{source_id.last(4)}")
      plan = service.plan(
        platform: :instagram,
        source_id: source_id,
        profile: { 'name' => 'Meta Name' },
        contact: contact
      )
      contact.update!(name: 'Agent Renamed')

      result = service.apply!(contact: contact, plan: plan)

      expect(result).to have_attributes(status: :unchanged, changed: false)
      expect(contact.reload.name).to eq('Agent Renamed')
    end
  end

  describe '#validate_apply_configuration!' do
    it 'rejects private-network SafeFetch mode before an apply run starts Meta access' do
      with_modified_env SAFE_FETCH_ALLOW_PRIVATE_NETWORK: 'true' do
        expect { service.validate_apply_configuration! }
          .to raise_error(described_class::UnsafeConfigurationError, 'private-network fetching is enabled')
      end
    end
  end

  describe '#attach_avatar' do
    let(:contact) { create(:contact) }

    before do
      image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
      image_file.rewind
    end

    it 'stops before fetching when the writer lease cannot be renewed' do
      lease_aware_service = described_class.new(
        sleeper: ->(_delay) {},
        renewer: -> { false }
      )
      allow(SafeFetch).to receive(:fetch)

      expect do
        lease_aware_service.attach_avatar(
          contact: contact,
          url: profile_url,
          remaining_budget_bytes: 15.megabytes
        )
      end.to raise_error(described_class::LeaseLost)

      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'preserves an existing avatar without fetching the candidate' do
      contact.avatar.attach(
        io: Rails.root.join('spec/assets/avatar.png').open,
        filename: 'existing.png',
        content_type: 'image/png'
      )
      allow(SafeFetch).to receive(:fetch)

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(status: :already_present, bytes_used: 0, incomplete: false)
      expect(SafeFetch).not_to have_received(:fetch)
      expect(contact.reload.avatar.filename.to_s).to eq('existing.png')
    end

    it 'uploads and directly inserts the exact Contact avatar association without saving Contact' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      allow(contact).to receive(:save!).and_call_original
      allow(contact).to receive(:update!).and_call_original
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      clear_enqueued_jobs

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )
      attachment = ActiveStorage::Attachment.find_by!(
        record_type: 'Contact',
        record_id: contact.id,
        name: 'avatar'
      )

      expect(result).to have_attributes(
        status: :attached,
        bytes_used: File.size(Rails.root.join('spec/assets/avatar.png')),
        mirror_jobs: 0,
        incomplete: false,
        cleanup_failed: false
      )
      expect(attachment.blob.filename.to_s).to eq('profile.png')
      expect(attachment.blob.content_type).to eq('image/png')
      expect(contact).not_to have_received(:save!)
      expect(contact).not_to have_received(:update!)
      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
      expect(enqueued_jobs).to be_empty
    end

    it 'keeps a concurrent winner and purges the importer blob on the unique-index race' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      original_blob_count = ActiveStorage::Blob.count
      winner = ActiveStorage::Blob.create_before_direct_upload!(
        filename: 'winner.png',
        byte_size: 6,
        checksum: Digest::MD5.base64digest('winner'),
        content_type: 'image/png'
      )
      ActiveStorage::Attachment.create!(name: 'avatar', record: contact, blob: winner)
      allow(ActiveStorage::Attachment).to receive(:exists?).and_return(false, false)
      allow(ActiveStorage::Attachment).to receive(:insert_all!).and_raise(ActiveRecord::RecordNotUnique)

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(status: :concurrent_avatar_preserved, incomplete: false)
      expect(contact.reload.avatar.blob_id).to eq(winner.id)
      expect(ActiveStorage::Blob.count).to eq(original_blob_count + 1)
    end

    it 'returns budget exhaustion without fetching or uploading' do
      allow(SafeFetch).to receive(:fetch)

      result = service.attach_avatar(contact: contact, url: profile_url, remaining_budget_bytes: 0)

      expect(result).to have_attributes(status: :budget_exhausted, incomplete: true, bytes_used: 0)
      expect(SafeFetch).not_to have_received(:fetch)
      expect(contact.reload.avatar).not_to be_attached
    end

    it 'enforces the smaller shared budget and reports oversized downloads as incomplete' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FileTooLargeError)

      result = service.attach_avatar(contact: contact, url: profile_url, remaining_budget_bytes: 1024)

      expect(SafeFetch).to have_received(:fetch).with(
        profile_url,
        max_bytes: 1024,
        allowed_content_type_prefixes: [],
        allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
      )
      expect(result).to have_attributes(status: :budget_exhausted, incomplete: true, bytes_used: 1024)
      expect(contact.reload.avatar).not_to be_attached
    end

    it 'treats an oversized avatar at the exact per-avatar cap as shared-budget exhaustion' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FileTooLargeError)

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: described_class::MAX_AVATAR_BYTES
      )

      expect(result).to have_attributes(
        status: :budget_exhausted,
        incomplete: true,
        degraded: false,
        bytes_used: described_class::MAX_AVATAR_BYTES
      )
    end

    it 'caps a standalone avatar at fifteen megabytes' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FileTooLargeError)

      result = service.attach_avatar(contact: contact, url: profile_url, remaining_budget_bytes: 100.megabytes)

      expect(SafeFetch).to have_received(:fetch).with(
        profile_url,
        max_bytes: 15.megabytes,
        allowed_content_type_prefixes: [],
        allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
      )
      expect(result).to have_attributes(
        status: :file_too_large,
        degraded: true,
        incomplete: false
      )
    end

    [
      [SafeFetch::InvalidUrlError, :invalid_url],
      [SafeFetch::UnsafeUrlError, :unsafe_url],
      [SafeFetch::UnsupportedContentTypeError, :unsupported_content_type],
      [SafeFetch::HttpError.new('404 Not Found'), :unavailable_url],
      [SafeFetch::HttpError.new('410 Gone'), :unavailable_url]
    ].each do |error, status|
      it "treats #{status} as a degradation without creating a blob" do
        allow(SafeFetch).to receive(:fetch).and_raise(error)
        blob_count = ActiveStorage::Blob.count

        result = service.attach_avatar(
          contact: contact,
          url: profile_url,
          remaining_budget_bytes: 15.megabytes
        )

        expect(result).to have_attributes(status: status, degraded: true, incomplete: false)
        expect(ActiveStorage::Blob.count).to eq(blob_count)
      end
    end

    [
      SafeFetch::HttpError.new('429 Too Many Requests'),
      SafeFetch::HttpError.new('503 Service Unavailable')
    ].each do |error|
      it "bounds retries for #{error.class.name} and returns a URL-free incomplete outcome" do
        allow(SafeFetch).to receive(:fetch).and_raise(error)

        result = service.attach_avatar(
          contact: contact,
          url: profile_url,
          remaining_budget_bytes: 15.megabytes
        )

        expect(SafeFetch).to have_received(:fetch).exactly(3).times
        expect(result.to_h.to_s).not_to include(profile_url)
        expect(result).to have_attributes(status: :retry_exhausted, incomplete: true, bytes_used: 0)
      end
    end

    it 'charges each transport retry cap and returns those bytes when retries are exhausted' do
      limits = []
      allow(SafeFetch).to receive(:fetch) do |_url, max_bytes:, **|
        limits << max_bytes
        raise SafeFetch::FetchError
      end

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 100.megabytes
      )

      expect(limits).to eq(Array.new(3, described_class::MAX_AVATAR_BYTES))
      expect(result).to have_attributes(
        status: :retry_exhausted,
        incomplete: true,
        bytes_used: 3 * described_class::MAX_AVATAR_BYTES
      )
    end

    it 'shrinks a later transport retry cap and stops when it consumes the shared remainder' do
      limits = []
      allow(SafeFetch).to receive(:fetch) do |_url, max_bytes:, **|
        limits << max_bytes
        raise SafeFetch::FetchError
      end
      remaining_budget = described_class::MAX_AVATAR_BYTES + 1024

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: remaining_budget
      )

      expect(limits).to eq([described_class::MAX_AVATAR_BYTES, 1024])
      expect(result).to have_attributes(
        status: :budget_exhausted,
        incomplete: true,
        bytes_used: remaining_budget
      )
    end

    it 'purges the staged blob and reports an upload failure as incomplete' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **attributes|
        blob = original.call(**attributes)
        allow(blob).to receive(:upload_without_unfurling).and_raise(StandardError, 'storage failed')
        blob
      end
      blob_count = ActiveStorage::Blob.count

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(status: :storage_error, incomplete: true)
      expect(ActiveStorage::Blob.count).to eq(blob_count)
    end

    it 'purges the staged blob and reports an association failure as incomplete' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      allow(ActiveStorage::Attachment).to receive(:insert_all!).and_raise(StandardError, 'database failed')
      blob_count = ActiveStorage::Blob.count

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(status: :association_error, incomplete: true)
      expect(ActiveStorage::Blob.count).to eq(blob_count)
    end

    it 'surfaces cleanup failure instead of reporting the original failed path as complete' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      allow(ActiveStorage::Attachment).to receive(:insert_all!).and_raise(StandardError, 'database failed')
      allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **attributes|
        blob = original.call(**attributes)
        allow(blob).to receive(:purge).and_raise(StandardError, 'cleanup failed')
        blob
      end

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(
        status: :cleanup_failed,
        incomplete: true,
        cleanup_failed: true
      )
    end

    it 'counts the one allowed Active Storage mirror upload job' do
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)
      mirror_service = ActiveStorage::Service::MirrorService.new(
        primary: ActiveStorage::Blob.service,
        mirrors: []
      )
      allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **attributes|
        blob = original.call(**attributes)
        allow(blob).to receive(:service).and_return(mirror_service)
        blob
      end
      contact
      clear_enqueued_jobs

      result = service.attach_avatar(
        contact: contact,
        url: profile_url,
        remaining_budget_bytes: 15.megabytes
      )

      expect(result).to have_attributes(status: :attached, mirror_jobs: 1, incomplete: false)
      expect(enqueued_jobs.map { |job| job[:job] }).to contain_exactly(ActiveStorage::MirrorJob)
    end
  end
end
