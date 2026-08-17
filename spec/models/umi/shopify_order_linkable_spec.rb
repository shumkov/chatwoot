# frozen_string_literal: true

require 'rails_helper'

# The behavior is installed through a rebase-safe concern rather than a public
# Message method, so the spec path intentionally describes the feature seam.
# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
RSpec.describe Message, 'with Shopify order-link rewriting' do
  before do
    allow(SendReplyJob).to receive(:perform_later)
    # Message's search callback is unrelated to this callback-chain contract.
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(described_class).to receive(:reindex_for_search).and_return(true)
    # rubocop:enable RSpec/AnyInstance
  end

  it 'adds a signed conversation token to outbound umi.store links before commit' do
    enqueued_content = nil
    allow(SendReplyJob).to receive(:perform_later) do |message_id|
      enqueued_content = described_class.find(message_id).content
    end
    message = build(
      :message,
      message_type: :outgoing,
      content: 'Your order is here: https://umi.store/products/test-handle'
    )

    message.save!

    expect(enqueued_content).to match(%r{https://umi\.store/products/test-handle\?umi_cw=[^\s]+})
  end

  it 'keeps creating the reply when Redis is unavailable' do
    allow(Redis::Alfred).to receive(:set).and_raise(Redis::CannotConnectError, 'Redis unavailable')
    allow(Redis::Alfred).to receive(:delete)
    enqueued_content = nil
    allow(SendReplyJob).to receive(:perform_later) do |message_id|
      enqueued_content = described_class.find(message_id).content
    end
    message = build(
      :message,
      message_type: :outgoing,
      content: 'Your order is here: https://umi.store/products/test-handle'
    )

    expect { message.save! }.not_to raise_error
    expect(message.reload.content).to eq('Your order is here: https://umi.store/products/test-handle')
    expect(enqueued_content).to eq('Your order is here: https://umi.store/products/test-handle')
    expect(SendReplyJob).to have_received(:perform_later).with(message.id)
  end

  it 'does not mint or rewrite when the runtime kill switch is enabled' do
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:mint)
    message = build(
      :message,
      message_type: :outgoing,
      content: 'Your order is here: https://umi.store/products/test-handle'
    )

    with_modified_env 'UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED' => 'true' do
      message.save!
    end

    expect(message.reload.content).to eq('Your order is here: https://umi.store/products/test-handle')
    expect(Umi::Shopify::OrderLinkTokenService).not_to have_received(:mint)
  end

  it 'does not rewrite incoming messages or private notes' do
    incoming = build(:message, content: 'https://umi.store/products/test-handle')
    private_note = build(:message, message_type: :outgoing, private: true, content: 'https://umi.store/products/test-handle')

    incoming.save!
    private_note.save!

    expect(incoming.reload.content).to eq('https://umi.store/products/test-handle')
    expect(private_note.reload.content).to eq('https://umi.store/products/test-handle')
  end

  it 'rewrites the derived HTML used for outbound email replies' do
    message = build(
      :message,
      message_type: :outgoing,
      content: 'Plain text fallback',
      content_attributes: {
        email: {
          html_content: {
            reply: '<p>Shop: https://umi.store/products/email-handle</p>',
            full: '<p>Shop: https://umi.store/products/email-handle</p>'
          }
        }
      }
    )

    message.save!

    expect(message.reload.content_attributes.to_json).to match(%r{umi\.store/products/email-handle\?umi_cw=})
  end
end
# rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
