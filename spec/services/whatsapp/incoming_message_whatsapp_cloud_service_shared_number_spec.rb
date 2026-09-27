require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageWhatsappCloudService do
  let!(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end

  let(:status_params) do
    {
      phone_number: whatsapp_channel.phone_number,
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          value: {
            statuses: [{
              id: 'wamid.klaviyo-only',
              status: 'delivered',
              recipient_id: '66975311301',
              timestamp: '1723939200'
            }]
          }
        }]
      }]
    }.with_indifferent_access
  end

  it 'ignores a status for a message not created in Chatwoot' do
    counts = {
      messages: Message.count,
      conversations: Conversation.count,
      contacts: Contact.count
    }

    expect do
      described_class.new(inbox: whatsapp_channel.inbox, params: status_params).perform
    end.not_to raise_error

    expect(Message.count).to eq(counts[:messages])
    expect(Conversation.count).to eq(counts[:conversations])
    expect(Contact.count).to eq(counts[:contacts])
  end
end
