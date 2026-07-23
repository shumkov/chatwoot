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
    calls = 0
    allow(SafeFetch).to receive(:fetch) do |_url, **, &block|
      calls += 1
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

    expect { service.stage(detail) }
      .to raise_error(described_class::TransientError)
      .and not_change(ActiveStorage::Blob, :count)
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
