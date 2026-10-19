require 'rails_helper'

RSpec.describe 'Cloud staff product shares', type: :request do
  let(:account) { create(:account) }
  let(:bridge) { create(:user, account: account, role: :administrator) }
  let(:staff) { create(:user, account: account) }
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:source) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: staff, private: true,
                     message_type: :outgoing, content: '/send-product 123')
  end
  let(:facts) do
    { product_id: 'gid://shopify/Product/10', title: 'Top', variant_id: '123', variant_title: 'Black / S',
      canonical_url: 'https://umi.store/products/top?variant=123', snapshot_at: Time.current.iso8601 }
  end
  let(:path) { "/api/v1/accounts/#{account.id}/umi/shopify/conversations/#{conversation.display_id}/product_shares" }
  let(:headers) { bridge.create_new_auth_token }

  before do
    allow(SendReplyJob).to receive(:perform_later)
    ENV['UMI_COMMERCE_BRIDGE_USER_ID'] = bridge.id.to_s
    ENV['UMI_COMMERCE_ACCOUNT_ID'] = account.id.to_s
    ENV['UMI_COMMERCE_CLOUD_INBOX_ID'] = channel.inbox.id.to_s
  end

  around do |example|
    with_modified_env UMI_COMMERCE_BRIDGE_USER_ID: nil, UMI_COMMERCE_ACCOUNT_ID: nil,
                      UMI_COMMERCE_CLOUD_INBOX_ID: nil do
      example.run
    end
  end

  it 'queues one normal attributed Cloud row for a verified staff command' do
    2.times { post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json }
    expect(response).to have_http_status(:ok)
    row = conversation.messages.where(private: false, message_type: :outgoing).sole
    expect(row.content).to include('https://umi.store/products/top?variant=123&umi_cw=')
    expect(row.content_attributes.fetch('umi_product_card')).to include('requested_by' => staff.id, 'source_id' => source.id)
    expect(row.sender).to eq(bridge)
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response.parsed_body).to include('status' => 'queued', 'message_id' => row.id)
  end

  it 'keeps internal snapshot terminology out of the customer caption' do
    post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
    row = conversation.messages.where(private: false, message_type: :outgoing).sole
    expect(row.content).to start_with("Top\nBlack / S\nhttps://umi.store/")
    expect(row.content).not_to include('snapshot')
    expect(row.content_attributes.dig('umi_product_card', 'snapshot_at')).to be_present
  end

  it 'does not admit the same command from an unconfigured Cloud inbox' do
    with_modified_env UMI_COMMERCE_CLOUD_INBOX_ID: '6' do
      post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
    end
    expect(response).to have_http_status(:forbidden)
    expect(conversation.messages.where(private: false, message_type: :outgoing)).to be_empty
  end
end
