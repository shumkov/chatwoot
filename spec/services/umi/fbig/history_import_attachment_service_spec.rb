require 'rails_helper'

describe Umi::Fbig::HistoryImportAttachmentService do
  let(:service) { described_class.new }
  let(:message) { create(:message) }
  let(:image_file) { Tempfile.new(['history-import', '.png'], binmode: true) }
  let(:image_result) do
    SafeFetch::Result.new(tempfile: image_file, filename: 'historical-image.png', content_type: 'image/png')
  end

  after do
    image_file.close!
  end

  it 'maps only the observed attachment shapes and caps each message at fifteen files' do
    attachments = [
      { 'image_data' => { 'url' => 'https://cdn.example/image.png' } },
      { 'video_data' => { 'url' => 'https://cdn.example/video.mp4' } },
      { 'file_url' => 'https://cdn.example/report.pdf' },
      { 'audio_data' => { 'url' => 'https://cdn.example/audio.mp3' } }
    ] + Array.new(13) { |index| { 'image_data' => { 'url' => "https://cdn.example/#{index}.png" } } }

    plan = service.plan('attachments' => { 'data' => attachments })

    expect(plan.descriptors.map(&:file_type).first(3)).to eq(%i[image video file])
    expect(plan.descriptors.size).to eq(15)
    expect(plan.omissions).to eq(unsupported_shape: 1, attachment_limit: 1)
  end

  it 'uploads a validated file and directly associates it with the historical message' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/signed-image' } }] } }
    timestamp = Time.zone.parse('2025-01-02 03:04:05 UTC')

    staged = service.stage(detail)
    count = service.persist!(staged, message_id: message.id, account_id: message.account_id, created_at: timestamp)
    attachment = message.attachments.reload.sole

    expect(count).to eq(1)
    expect(attachment).to have_attributes(file_type: 'image', extension: 'png', created_at: timestamp, updated_at: timestamp)
    expect(attachment.meta).to eq('umi_history_import' => true)
    expect(attachment.external_url).to be_nil
    expect(attachment.file).to be_attached
    expect(attachment.file.filename.to_s).to eq('historical-image.png')
    expect(attachment.file.content_type).to eq('image/png')
  end

  it 'marks staged production blobs durably and clears the intent only after association' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/signed-image' } }] } }
    intent = described_class::Intent.new(
      run_id: SecureRandom.uuid,
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      platform: 'instagram',
      thread_id: 'thread-private',
      mid: 'mid-private'
    )

    staged = service.stage(detail, intent: intent)
    blob = staged.attachments.sole.blob.reload
    expect(blob.metadata.fetch(described_class::INTENT_KEY)).to include(
      'schema_version' => 1,
      'run_id' => intent.run_id,
      'inbox_id' => message.inbox_id,
      'platform' => 'instagram'
    )

    service.persist!(
      staged,
      message_id: message.id,
      account_id: message.account_id,
      created_at: Time.current
    )

    expect(blob.reload.metadata).not_to have_key(described_class::INTENT_KEY)
  end

  it 'reconciles a hard-kill orphan from its durable staging intent' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/signed-image' } }] } }
    intent = described_class::Intent.new(
      run_id: SecureRandom.uuid,
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      platform: 'messenger',
      thread_id: 'thread-private',
      mid: 'mid-private'
    )
    staged = service.stage(detail, intent: intent)
    blob_id = staged.attachments.sole.blob.id

    result = described_class.reconcile!(inbox: message.inbox)

    expect(result).to eq(purged: 1, attached: 0)
    expect(ActiveStorage::Blob).not_to exist(blob_id)
  end

  it 'retries safely when reconciliation stops after deleting storage but before deleting the blob row' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/signed-image' } }] } }
    intent = described_class::Intent.new(
      run_id: SecureRandom.uuid,
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      platform: 'messenger',
      thread_id: 'thread-private',
      mid: 'mid-private'
    )
    staged = service.stage(detail, intent: intent)
    blob = staged.attachments.sole.blob
    blob_id = blob.id
    blob_key = blob.key
    destroy_calls = 0
    allow(ActiveStorage::Blob).to receive(:find_each).and_yield(blob)
    allow(blob).to receive(:destroy!).and_wrap_original do |original, *arguments|
      destroy_calls += 1
      raise StandardError, 'hard stop' if destroy_calls == 1

      original.call(*arguments)
    end

    expect do
      described_class.reconcile!(inbox: message.inbox)
    end.to raise_error(described_class::CleanupError, 'StandardError')
    expect(ActiveStorage::Blob).to exist(blob_id)
    expect(blob.service).not_to exist(blob_key)

    result = described_class.reconcile!(inbox: message.inbox)

    expect(result).to eq(purged: 1, attached: 0)
    expect(ActiveStorage::Blob).not_to exist(blob_id)
    expect(blob.service).not_to exist(blob_key)
  end

  it 'clears an intent left after its exact historical attachment committed' do
    message.update!(
      source_id: 'mid-private',
      additional_attributes: {
        'umi_history_import' => true,
        'umi_history_platform' => 'messenger',
        'umi_history_thread_id' => 'thread-private'
      }
    )
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/signed-image' } }] } }
    intent = described_class::Intent.new(
      run_id: SecureRandom.uuid,
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      platform: 'messenger',
      thread_id: 'thread-private',
      mid: message.source_id
    )
    staged = service.stage(detail, intent: intent)
    blob = staged.attachments.sole.blob
    marker = blob.metadata.fetch(described_class::INTENT_KEY)
    service.persist!(
      staged,
      message_id: message.id,
      account_id: message.account_id,
      created_at: Time.current
    )
    blob.reload.update!(metadata: blob.metadata.merge(described_class::INTENT_KEY => marker))

    result = described_class.reconcile!(inbox: message.inbox)

    expect(result).to eq(purged: 0, attached: 1)
    expect(blob.reload.metadata).not_to have_key(described_class::INTENT_KEY)
  end

  it 'fails closed on an invalid staging marker even when it names another inbox' do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('staged'),
      filename: 'staged.txt',
      content_type: 'text/plain',
      metadata: {
        described_class::INTENT_KEY => {
          'schema_version' => 1,
          'account_id' => message.account_id + 1,
          'inbox_id' => message.inbox_id + 1
        }
      }
    )

    expect do
      described_class.reconcile!(inbox: message.inbox)
    end.to raise_error(described_class::CleanupError, 'invalid staged attachment marker')
    expect(blob.reload).to be_present
  ensure
    blob&.purge
  end

  it 'records permanently unavailable files without creating blobs' do
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::UnsafeUrlError)
    detail = { 'attachments' => { 'data' => [{ 'file_url' => 'https://cdn.example/private' }] } }

    blob_count = ActiveStorage::Blob.count
    result = service.stage(detail)

    expect(ActiveStorage::Blob.count).to eq(blob_count)
    expect(result.attachments).to be_empty
    expect(result.omissions).to eq(unsafe_url: 1)
  end

  it 'purges already uploaded blobs when a later attachment fails transiently' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    limits = []
    calls = 0
    allow(SafeFetch).to receive(:fetch) do |_url, max_bytes:, **, &block|
      calls += 1
      limits << max_bytes
      calls == 1 ? block.call(image_result) : raise(SafeFetch::FetchError)
    end
    detail = {
      'attachments' => {
        'data' => [
          { 'image_data' => { 'url' => 'https://cdn.example/first.png' } },
          { 'image_data' => { 'url' => 'https://cdn.example/second.png' } }
        ]
      }
    }
    remaining_budget = image_file.size + 3

    error = nil
    expect do
      service.stage(detail, remaining_budget_bytes: remaining_budget)
    rescue described_class::TransientError => e
      error = e
      raise
    end.to raise_error(described_class::TransientError)
      .and not_change(ActiveStorage::Blob, :count)
    expect(error).to have_attributes(bytes_used: remaining_budget, budget_exhausted: true)
    expect(limits).to eq([remaining_budget, 3])
  end

  it 'charges the per-file cap when a transport failure may have partially streamed a file' do
    allow(service).to receive(:default_max_bytes).and_return(10)
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::FetchError)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }
    error = nil

    expect do
      service.stage(detail)
    rescue described_class::TransientError => e
      error = e
      raise
    end.to raise_error(described_class::TransientError)
    expect(error).to have_attributes(bytes_used: 10, budget_exhausted: false)
  end

  it 'does not charge an HTTP retry response that never reached the stream callback' do
    allow(service).to receive(:default_max_bytes).and_return(10)
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '503 Service Unavailable')
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }
    error = nil

    expect do
      service.stage(detail)
    rescue described_class::TransientError => e
      error = e
      raise
    end.to raise_error(described_class::TransientError)
    expect(error).to have_attributes(bytes_used: 0, budget_exhausted: false)
  end

  it 'charges a downloaded attachment when its blob upload fails' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **attributes|
      blob = original.call(**attributes)
      allow(blob).to receive(:upload_without_unfurling).and_raise(StandardError, 'storage failed')
      blob
    end
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }
    error = nil

    expect do
      service.stage(detail)
    rescue described_class::TransientError => e
      error = e
      raise
    end.to raise_error(described_class::TransientError)
      .and not_change(ActiveStorage::Blob, :count)
    expect(error.bytes_used).to eq(image_file.size)
  end

  it 'allows a staged attachment to exactly consume the remaining shared download budget' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }

    result = service.stage(detail, remaining_budget_bytes: image_file.size)

    expect(result.attachments.size).to eq(1)
    expect(result.bytes_used).to eq(image_file.size)
  ensure
    service.cleanup_unattached!(result) if result
  end

  it 'purges a staged attachment that crosses the remaining shared download budget by one byte' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }
    error = nil

    expect do
      service.stage(detail, remaining_budget_bytes: image_file.size - 1)
    rescue described_class::BudgetExceeded => e
      error = e
      raise
    end.to raise_error(described_class::BudgetExceeded)
      .and not_change(ActiveStorage::Blob, :count)
    expect(error.bytes_used).to eq(image_file.size)
  end

  it 'fails before fetching when the shared download budget is already exhausted' do
    allow(SafeFetch).to receive(:fetch)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }

    expect do
      service.stage(detail, remaining_budget_bytes: 0)
    end.to raise_error(described_class::BudgetExceeded) { |error| expect(error.bytes_used).to eq(0) }
    expect(SafeFetch).not_to have_received(:fetch)
  end

  it 'accounts for the first staged attachment when the second attachment crosses the remaining budget' do
    first_file = Tempfile.new(['history-import-first', '.png'], binmode: true)
    first_file.write('first')
    first_file.rewind
    first_result = SafeFetch::Result.new(tempfile: first_file, filename: 'first.png', content_type: 'image/png')
    limits = []
    calls = 0
    allow(SafeFetch).to receive(:fetch) do |_url, max_bytes:, **, &block|
      calls += 1
      limits << max_bytes
      calls == 1 ? block.call(first_result) : raise(SafeFetch::FileTooLargeError)
    end
    detail = {
      'attachments' => {
        'data' => [
          { 'image_data' => { 'url' => 'https://cdn.example/first.png' } },
          { 'image_data' => { 'url' => 'https://cdn.example/second.png' } }
        ]
      }
    }
    error = nil
    remaining_budget = first_file.size + 3

    expect do
      service.stage(detail, remaining_budget_bytes: remaining_budget)
    rescue described_class::BudgetExceeded => e
      error = e
      raise
    end.to raise_error(described_class::BudgetExceeded)
      .and not_change(ActiveStorage::Blob, :count)
    expect(error.bytes_used).to eq(remaining_budget)
    expect(limits).to eq([remaining_budget, 3])
  ensure
    first_file&.close!
  end

  it 'preserves budget exhaustion and consumed bytes when staged-blob cleanup fails' do
    first_file = Tempfile.new(['history-import-first', '.png'], binmode: true)
    first_file.write('first')
    first_file.rewind
    first_result = SafeFetch::Result.new(tempfile: first_file, filename: 'first.png', content_type: 'image/png')
    calls = 0
    allow(SafeFetch).to receive(:fetch) do |_url, **, &block|
      calls += 1
      calls == 1 ? block.call(first_result) : raise(SafeFetch::FileTooLargeError)
    end
    allow(ActiveStorage::Blob).to receive(:find_by).and_wrap_original do |original, **attributes|
      blob = original.call(**attributes)
      allow(blob).to receive(:purge).and_raise(StandardError, 'storage unavailable')
      blob
    end
    detail = {
      'attachments' => {
        'data' => [
          { 'image_data' => { 'url' => 'https://cdn.example/first.png' } },
          { 'image_data' => { 'url' => 'https://cdn.example/second.png' } }
        ]
      }
    }
    error = nil
    remaining_budget = first_file.size + 3

    expect do
      service.stage(detail, remaining_budget_bytes: remaining_budget)
    rescue described_class::CleanupError => e
      error = e
      raise
    end.to raise_error(described_class::CleanupError)
    expect(error).to have_attributes(bytes_used: remaining_budget, budget_exhausted: true)
  ensure
    first_file&.close!
  end

  it 'charges the per-file cap for an oversized file and reduces the next attachment limit' do
    accepted_file = Tempfile.new(['history-import-accepted', '.png'], binmode: true)
    accepted_file.write('okay')
    accepted_file.rewind
    accepted_result = SafeFetch::Result.new(tempfile: accepted_file, filename: 'accepted.png', content_type: 'image/png')
    limits = []
    calls = 0
    allow(service).to receive(:default_max_bytes).and_return(10)
    allow(SafeFetch).to receive(:fetch) do |_url, max_bytes:, **, &block|
      calls += 1
      limits << max_bytes
      calls == 1 ? raise(SafeFetch::FileTooLargeError) : block.call(accepted_result)
    end
    detail = {
      'attachments' => {
        'data' => [
          { 'file_url' => 'https://cdn.example/oversized.pdf' },
          { 'image_data' => { 'url' => 'https://cdn.example/accepted.png' } }
        ]
      }
    }

    result = service.stage(detail, remaining_budget_bytes: 15)

    expect(result.omissions).to eq(file_too_large: 1)
    expect(result.bytes_used).to eq(14)
    expect(limits).to eq([10, 5])
  ensure
    service.cleanup_unattached!(result) if result
    accepted_file&.close!
  end

  it 'charges a rejected generic download against this result and the next attachment limit' do
    rejected_file = Tempfile.new(['history-import-rejected', '.exe'], binmode: true)
    accepted_file = Tempfile.new(['history-import-accepted', '.png'], binmode: true)
    rejected_file.write('bad')
    rejected_file.rewind
    accepted_file.write('ok')
    accepted_file.rewind
    results = {
      'https://cdn.example/rejected.exe' => SafeFetch::Result.new(
        tempfile: rejected_file,
        filename: 'rejected.exe',
        content_type: 'application/octet-stream'
      ),
      'https://cdn.example/accepted.png' => SafeFetch::Result.new(
        tempfile: accepted_file,
        filename: 'accepted.png',
        content_type: 'image/png'
      )
    }
    limits = []
    allow(SafeFetch).to receive(:fetch) do |url, max_bytes:, **, &block|
      limits << max_bytes
      block.call(results.fetch(url))
    end
    detail = {
      'attachments' => {
        'data' => [
          { 'file_url' => 'https://cdn.example/rejected.exe' },
          { 'image_data' => { 'url' => 'https://cdn.example/accepted.png' } }
        ]
      }
    }

    result = service.stage(detail, remaining_budget_bytes: rejected_file.size + accepted_file.size)

    expect(result.attachments.size).to eq(1)
    expect(result.omissions).to eq(unsupported_content_type: 1)
    expect(result.bytes_used).to eq(rejected_file.size + accepted_file.size)
    expect(limits).to eq([rejected_file.size + accepted_file.size, accepted_file.size])
  ensure
    service.cleanup_unattached!(result) if result
    rejected_file&.close!
    accepted_file&.close!
  end

  it 'keeps associated blobs and purges only unattached staged blobs' do
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    allow(SafeFetch).to receive(:fetch).and_yield(image_result)
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }
    staged = service.stage(detail)

    service.persist!(staged, message_id: message.id, account_id: message.account_id, created_at: Time.current)

    expect { service.cleanup_unattached!(staged) }.not_to change(ActiveStorage::Blob, :count)
  end

  it 'attempts every staged blob cleanup when an earlier purge fails' do
    first_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('first'),
      filename: 'first.txt',
      content_type: 'text/plain'
    )
    second_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('second'),
      filename: 'second.txt',
      content_type: 'text/plain'
    )
    third_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('third'),
      filename: 'third.txt',
      content_type: 'text/plain'
    )
    first_result = described_class::StageResult.new(
      attachments: [
        described_class::StagedAttachment.new(blob: first_blob, file_type: :file, extension: 'txt'),
        described_class::StagedAttachment.new(blob: second_blob, file_type: :file, extension: 'txt')
      ],
      omissions: {}
    )
    second_result = described_class::StageResult.new(
      attachments: [
        described_class::StagedAttachment.new(blob: third_blob, file_type: :file, extension: 'txt')
      ],
      omissions: {}
    )
    allow(ActiveStorage::Blob).to receive(:find_by).with(id: first_blob.id).and_return(first_blob)
    allow(ActiveStorage::Blob).to receive(:find_by).with(id: second_blob.id).and_return(second_blob)
    allow(ActiveStorage::Blob).to receive(:find_by).with(id: third_blob.id).and_return(third_blob)
    allow(first_blob).to receive(:purge).and_raise(StandardError, 'storage unavailable')
    allow(second_blob).to receive(:purge)
    allow(third_blob).to receive(:purge)

    expect { service.cleanup_all_unattached!([first_result, second_result]) }.to raise_error(described_class::CleanupError)
    expect(second_blob).to have_received(:purge)
    expect(third_blob).to have_received(:purge)
  end

  it 'refuses to download history when private-network fetching is enabled' do
    detail = { 'attachments' => { 'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/image.png' } }] } }

    with_modified_env SAFE_FETCH_ALLOW_PRIVATE_NETWORK: 'true' do
      expect { service.stage(detail) }.to raise_error(described_class::UnsafeConfigurationError)
    end
  end
end
