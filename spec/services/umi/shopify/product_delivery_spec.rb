require 'rails_helper'

RSpec.describe Umi::Shopify::ProductDelivery do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:staff) { create(:user, account: account) }
  let(:bridge) { create(:user, account: account) }
  let(:source) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: staff, private: true, message_type: :outgoing,
                     content: '/send-product https://umi.store/products/top')
  end
  let(:token) do
    Umi::Shopify::OrderLinkTokenService.mint(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id)
  end
  let(:card) { { 'version' => 1, 'title' => 'Top', 'url' => "https://umi.store/products/top?umi_cw=#{token}", 'source_id' => source.id, 'requested_by' => staff.id } }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: bridge, message_type: :outgoing, content: 'Top',
                     content_attributes: { 'umi_product_card' => card })
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(Facebook::Messenger::Bot).to receive(:deliver).and_return({ message_id: 'mid.card' }.to_json)
    allow(SendReplyJob).to receive(:perform_later)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    ENV['UMI_COMMERCE_BRIDGE_USER_ID'] = bridge.id.to_s
    ENV['UMI_COMMERCE_ACCOUNT_ID'] = account.id.to_s
    ENV['UMI_COMMERCE_META_INBOX_ID'] = inbox.id.to_s
  end

  around do |example|
    with_modified_env UMI_COMMERCE_BRIDGE_USER_ID: nil, UMI_COMMERCE_ACCOUNT_ID: nil, UMI_COMMERCE_META_INBOX_ID: nil do
      example.run
    end
  end

  it 'sends exactly one generic card with standard response policy and preserves provider acceptance' do
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).to have_received(:deliver).once.with(
      hash_including(messaging_type: 'RESPONSE', message: { attachment: { type: 'template', payload: {
                       template_type: 'generic', elements: [{ title: 'Top', buttons: [{ type: 'web_url', url: card['url'], title: 'View product' }] }]
                     } } }), page_id: channel.page_id
    )
    expect(message.reload.source_id).to eq('mid.card')
    expect(message.content_attributes.dig('umi_product_delivery', 'state')).to eq('accepted')
  end

  it 'holds cards by default instead of delivering the text summary' do
    SendReplyJob.perform_now(message.id)
    expect(Facebook::Messenger::Bot).not_to have_received(:deliver)
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
  end

  it 'records a Facebook SDK rejection as definite so the operator can retry' do
    allow(Facebook::Messenger::Bot).to receive(:deliver).and_raise(Facebook::Messenger::FacebookError.new('message' => 'Permission denied',
                                                                                                          'code' => 10))
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('rejected')
    expect(message.status).to eq('failed')
  end

  it 'never replays a timeout or a duplicate job' do
    allow(Facebook::Messenger::Bot).to receive(:deliver).and_raise(Net::ReadTimeout)
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).to have_received(:deliver).once
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('ambiguous')
    expect(message.status).to eq('failed')
  end

  it 'keeps provider rejection definite and holds an expired standard window' do
    allow(Facebook::Messenger::Bot).to receive(:deliver).and_return({ error: { code: 10, message: 'Denied' } }.to_json)
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('rejected')
    expect(message.status).to eq('failed')
    conversation.messages.incoming.each { |incoming| incoming.update!(created_at: 25.hours.ago) }
    message.update!(content_attributes: message.content_attributes.except('umi_product_delivery'))
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).to have_received(:deliver).once
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
  end

  it 'routes Page-linked Instagram through its Page credentials with exactly one generic card call' do
    conversation.update!(additional_attributes: { type: 'instagram_direct_message' })
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return('app-secret')
    provider = instance_double(HTTParty::Response, parsed_response: { 'message_id' => 'ig.card' })
    allow(HTTParty).to receive(:post).and_return(provider)
    with_modified_env UMI_PRODUCT_CARDS_INSTAGRAM_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('accepted'), message.external_error
    expect(HTTParty).to have_received(:post).once.with('https://graph.facebook.com/v21.0/me/messages',
                                                       hash_including(body: hash_including(messaging_type: 'RESPONSE'),
                                                                      query: hash_including(access_token: channel.page_access_token)))
    expect(Facebook::Messenger::Bot).not_to have_received(:deliver)
    expect(message.reload.source_id).to eq('ig.card')
  end

  it 'holds an expired or rebound attribution before any provider call' do
    message
    Umi::Shopify::OrderLinkTokenService.discard(token)
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).not_to have_received(:deliver)
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
  end

  it 'holds a command deleted after queueing and a mismatched service principal' do
    message
    source.update!(content_attributes: { deleted: true })
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true' do
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).not_to have_received(:deliver)
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
    source.update!(content_attributes: {})
    message.update!(content_attributes: message.content_attributes.except('umi_product_delivery'))
    with_modified_env UMI_PRODUCT_CARDS_FACEBOOK_ENABLED: 'true', UMI_COMMERCE_BRIDGE_USER_ID: '999999' do
      SendReplyJob.perform_now(message.id)
    end
    expect(Facebook::Messenger::Bot).not_to have_received(:deliver)
  end
end
