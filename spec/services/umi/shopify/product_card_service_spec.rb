# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ProductCardService do
  let(:conversation) { create(:conversation) }
  let(:facts) do
    { 'product_id' => 'gid://shopify/Product/10', 'title' => 'Top', 'variant_id' => '123', 'variant_title' => 'Black / S',
      'image_url' => 'https://cdn.shopify.com/top.jpg', 'canonical_url' => 'https://umi.store/products/top?variant=123',
      'snapshot_at' => Time.current.iso8601 }
  end

  before do
    allow(SendReplyJob).to receive(:perform_later)
    allow_any_instance_of(Message).to receive(:reindex_for_search).and_return(true) # rubocop:disable RSpec/AnyInstance
  end

  it 'persists an ordinary readable message and one immutable attributed card snapshot' do
    message = described_class.new(conversation: conversation, facts: facts, source_id: 45, requested_by: 7).perform
    message.reload
    card = message.content_attributes.fetch('umi_product_card')
    uri = URI.parse(card.fetch('url'))
    token = URI.decode_www_form(uri.query).to_h.fetch('umi_cw')
    expect(Umi::Shopify::OrderLinkTokenService.peek(token)).to include('conversation_id' => conversation.id)
    expect(URI.decode_www_form(uri.query).count { |key, _| key == 'umi_cw' }).to eq(1)
    expect(message.content_type).to eq('text')
    expect(message.content).to include('Top', 'Black / S', 'snapshot')
    expect(card).to include('source_id' => 45, 'requested_by' => 7, 'version' => 1)
    expect(card).not_to have_key('price')
  end

  it 'fails closed before a message exists when attribution cannot be minted' do
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:mint).and_raise(Redis::CannotConnectError)
    expect do
      expect { described_class.new(conversation: conversation, facts: facts, source_id: 45, requested_by: 7).perform }
        .to raise_error(Redis::CannotConnectError)
    end.not_to change(Message, :count)
  end
end
