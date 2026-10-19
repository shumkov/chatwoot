require 'rails_helper'

RSpec.describe 'Staff product shares', type: :request do
  let(:account) { create(:account) }
  let(:bridge) { create(:user, account: account, role: :administrator) }
  let(:staff) { create(:user, account: account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:source) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: staff, private: true, message_type: :outgoing,
                     content: '/send-product 123')
  end
  let(:facts) { { product_id: 'gid://shopify/Product/10', title: 'Top', variant_id: '123', variant_title: 'Black / S', canonical_url: 'https://umi.store/products/top?variant=123', snapshot_at: Time.current.iso8601 } }
  let(:path) { "/api/v1/accounts/#{account.id}/umi/shopify/conversations/#{conversation.display_id}/product_shares" }
  let(:headers) { bridge.create_new_auth_token }

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(SendReplyJob).to receive(:perform_later)
    ENV['UMI_COMMERCE_BRIDGE_USER_ID'] = bridge.id.to_s
    ENV['UMI_COMMERCE_ACCOUNT_ID'] = account.id.to_s
    ENV['UMI_COMMERCE_META_INBOX_ID'] = inbox.id.to_s
  end

  around do |example|
    with_modified_env UMI_COMMERCE_BRIDGE_USER_ID: nil, UMI_COMMERCE_ACCOUNT_ID: nil, UMI_COMMERCE_META_INBOX_ID: nil do
      example.run
    end
  end

  it 'binds one normal outgoing message to the current staff source and service principal, including duplicate POST and GET readback' do
    2.times { post path, params: { source_message_id: source.id, requested_by: 999, facts: facts }, headers: headers, as: :json }
    expect(response).to have_http_status(:ok)
    rows = conversation.messages.where(private: false, message_type: :outgoing)
    expect(rows.count).to eq(1), rows.map { |m| [m.id, m.content_attributes] }.inspect
    row = rows.sole
    expect(row.sender).to eq(bridge)
    expect(row.content_attributes['umi_product_card']).to include('requested_by' => staff.id, 'source_id' => source.id)
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response.parsed_body).to include('status' => 'queued', 'message_id' => row.id)
  end

  it 'rejects a stale, deleted, public, nonstaff, removed staff or product-mismatched source without creating an outgoing share' do
    [{ private: false }, { content: '/send-product 456' }, { content_attributes: { deleted: true } },
     { content_attributes: { shumabit_bridge: true } }, { sender: conversation.contact }].each do |change|
      source.update!(change)
      post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.messages.where(private: false, message_type: :outgoing).where.not(id: source.id)).to be_empty
      source.update!(private: true, content: '/send-product 123', content_attributes: {}, sender: staff)
    end
    account.account_users.find_by!(user_id: staff.id).destroy!
    post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'accepts the operator own command when the bridge reuses that operator token' do
    source.update!(sender: bridge)
    post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    row = conversation.messages.find(response.parsed_body.fetch('message_id'))
    expect(row.content_attributes['umi_product_card']['requested_by']).to eq(bridge.id)
  end

  it 'rejects an unconfigured service principal and source from another conversation' do
    post path, params: { source_message_id: source.id, facts: facts }, headers: staff.create_new_auth_token, as: :json
    expect(response).not_to have_http_status(:ok)
    other = create(:message, account: account)
    post path, params: { source_message_id: other.id, facts: facts }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'preserves card and requester on definite-failure Retry, and blocks uncertain or queued Retry' do
    post path, params: { source_message_id: source.id, facts: facts }, headers: headers, as: :json
    row = conversation.messages.find(response.parsed_body.fetch('message_id'))
    retry_path = "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{row.id}/retry"
    card = row.content_attributes.fetch('umi_product_card')
    %w[ambiguous dispatching accepted held].each do |state|
      row.update!(content_attributes: row.content_attributes.merge('umi_product_delivery' => { 'state' => state }))
      post retry_path, headers: headers
      expect(response).to have_http_status(:conflict)
      expect(row.reload.content_attributes['umi_product_card']).to eq(card)
    end
    row.update!(status: :failed, content_attributes: row.content_attributes.merge('umi_product_delivery' => { 'state' => 'rejected' }))
    post retry_path, headers: headers
    expect(response).to have_http_status(:accepted)
    expect(row.reload.content_attributes['umi_product_card']).to eq(card)
    expect(row.content_attributes).not_to have_key('umi_product_delivery')
  end
end
