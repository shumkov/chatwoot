require 'rails_helper'

RSpec.describe Umi::Fbig::UnavailableMessageThreadFingerprint do
  let(:first_record) do
    {
      'thread_id' => 'thread-1',
      'external_participant_id' => 'user-1',
      'archive_present' => true,
      'http_status' => 400,
      'error_code' => -1,
      'error_subcode' => 2_207_085,
      'error_type' => 'OAuthException'
    }
  end
  let(:second_record) do
    {
      'thread_id' => 'thread-2',
      'external_participant_id' => 'user-2',
      'archive_present' => false,
      'http_status' => 400,
      'error_code' => -1,
      'error_subcode' => 2_207_085,
      'error_type' => 'OAuthException'
    }
  end

  it 'pins platform-specific empty fingerprints' do
    expect(described_class.build(platform: 'messenger', records: []).to_h).to eq(
      count: 0,
      fingerprint: '901290cdf01a1cd38b6c8ac38c1a36fb1b02376245c8237a44fc6252971bf1fa'
    )
    expect(described_class.build(platform: 'instagram', records: []).to_h).to eq(
      count: 0,
      fingerprint: 'bd73d5c7d96c25c097496395aec4bdd8ce66b3bd8ef474bf4a4f5cb2d317ca17'
    )
  end

  it 'sorts exact typed records by thread id bytes before hashing' do
    forward = described_class.build(platform: 'instagram', records: [second_record, first_record])
    reverse = described_class.build(platform: 'instagram', records: [first_record, second_record])

    expect(forward).to eq(reverse)
    expect(forward.to_h).to eq(
      count: 2,
      fingerprint: '3cd76b2a651ef9eab0883e3d7969b3257df34336dd44a2e7e3b05dc6c763042b'
    )
  end

  it 'rejects duplicate thread ids and nonempty Messenger records' do
    duplicate = second_record.merge(
      'thread_id' => first_record.fetch('thread_id'),
      'external_participant_id' => 'another-user'
    )

    expect do
      described_class.build(platform: 'instagram', records: [first_record, duplicate])
    end.to raise_error(described_class::DuplicateThreadIdError)
    expect do
      described_class.build(platform: 'messenger', records: [first_record])
    end.to raise_error(described_class::InvalidRecordError)
  end

  it 'rejects invalid encoding, fields, types, and error shapes' do
    invalid_thread_id = "\xFF".dup.force_encoding(Encoding::UTF_8)
    invalid_records = [
      first_record.merge('thread_id' => invalid_thread_id),
      first_record.except('archive_present'),
      first_record.merge('archive_present' => 1),
      first_record.merge('error_subcode' => 2_207_086),
      first_record.merge('response_message' => 'must not enter the digest')
    ]

    invalid_records.each do |record|
      expect do
        described_class.build(platform: 'instagram', records: [record])
      end.to raise_error(described_class::InvalidRecordError)
    end
  end
end
