require 'rails_helper'

RSpec.describe Umi::Shopify::CloudProductIncoming do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:source_id) { "wamid.#{SecureRandom.hex(8)}" }
  let(:message) { { id: source_id, from: '2423423243', timestamp: '1664799904' } }
  let(:params) do
    { object: 'whatsapp_business_account', entry: [{ changes: [{ value: {
      contacts: [{ profile: { name: 'Customer' }, wa_id: '2423423243' }], messages: [message]
    } }] }] }.with_indifferent_access
  end

  it 'shows every cart item with provider IDs but creates no Shopify purchase or payment' do
    message.merge!(type: 'order', order: { catalog_id: 'catalog-1', text: 'Please confirm sizes',
                                           product_items: [{ product_retailer_id: 'retailer-a', quantity: 2 },
                                                           { product_retailer_id: 'retailer-b', quantity: 1 }] })
    described_class = Whatsapp::IncomingMessageWhatsappCloudService
    expect { described_class.new(inbox: channel.inbox, params: params).perform }.to change(Message, :count).by(1)
    row = channel.inbox.messages.find_by!(source_id: source_id)
    expect(row).to be_incoming
    expect(row.content).to include('retailer-a × 2', 'retailer-b × 1', 'No Shopify order or payment was created')
    expect(row.content_attributes.fetch('umi_whatsapp_catalog')).to include('kind' => 'order', 'mapped' => false,
                                                                            'catalog_id' => 'catalog-1')
    expect(row.content_attributes.dig('umi_whatsapp_catalog', 'items').length).to eq(2)
    described_class.new(inbox: channel.inbox, params: params).perform
    expect(channel.inbox.messages.where(source_id: source_id).count).to eq(1)
  end

  it 'shows an unmapped product enquiry with its original customer text' do
    message.merge!(type: 'text', text: { body: 'Does it come in black?' },
                   context: { referred_product: { catalog_id: 'catalog-1', product_retailer_id: 'retailer-a' } })
    Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    row = channel.inbox.messages.find_by!(source_id: source_id)
    expect(row.content).to include('Does it come in black?', 'retailer-a')
    expect(row.content_attributes.fetch('umi_whatsapp_catalog')).to include('kind' => 'enquiry', 'mapped' => false)
  end

  it 'keeps a malformed cart visible for human review without inventing a variant' do
    message.merge!(type: 'order', order: { catalog_id: 'catalog-1', product_items: [] })
    Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    row = channel.inbox.messages.find_by!(source_id: source_id)
    expect(row.content).to include('Item details unavailable')
    expect(row.content_attributes.dig('umi_whatsapp_catalog', 'items')).to eq([])
  end
end
