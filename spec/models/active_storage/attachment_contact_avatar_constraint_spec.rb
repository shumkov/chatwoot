# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActiveStorage::Attachment do
  let(:contact) { create(:contact) }
  let(:first_blob) do
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'first.png',
      byte_size: 5,
      checksum: Digest::MD5.base64digest('first'),
      content_type: 'image/png'
    )
  end
  let(:second_blob) do
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'second.png',
      byte_size: 6,
      checksum: Digest::MD5.base64digest('second'),
      content_type: 'image/png'
    )
  end

  it 'rejects a second avatar attachment for the same contact at the database boundary' do
    described_class.create!(name: 'avatar', record: contact, blob: first_blob)

    expect do
      described_class.create!(name: 'avatar', record: contact, blob: second_blob)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows two avatar attachments for a non-contact record' do
    user = create(:user)

    described_class.create!(name: 'avatar', record: user, blob: first_blob)

    expect do
      described_class.create!(name: 'avatar', record: user, blob: second_blob)
    end.not_to raise_error
  end

  it 'allows two non-avatar attachments for a contact' do
    attachment_attributes = {
      name: 'profile_image',
      record_type: 'Contact',
      record_id: contact.id,
      created_at: Time.current
    }
    rows = [
      attachment_attributes.merge(blob_id: first_blob.id),
      attachment_attributes.merge(blob_id: second_blob.id)
    ]

    # This shape bypasses callbacks because Contact intentionally has no
    # non-avatar attachment association; the database predicate is under test.
    # rubocop:disable Rails/SkipsModelValidations
    expect do
      described_class.insert_all!(rows)
    end.not_to raise_error
    # rubocop:enable Rails/SkipsModelValidations
  end
end
