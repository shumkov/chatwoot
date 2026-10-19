require 'rails_helper'

RSpec.describe Umi::Shopify::CloudProductDelivery do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:staff) { create(:user, account: account) }
  let(:bridge) { create(:user, account: account) }
  let(:source) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: staff, private: true,
                     message_type: :outgoing, content: '/send-product 123')
  end
  let!(:incoming) { create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming) }
  let(:token) do
    Umi::Shopify::OrderLinkTokenService.mint(
      account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id
    )
  end
  let(:url) { "https://umi.store/products/top?variant=123&umi_cw=#{token}" }
  let(:card) do
    { 'version' => 1, 'title' => 'Top', 'variant_id' => '123', 'variant_title' => 'Black / S',
      'image_url' => 'https://cdn.example.com/top.jpg', 'url' => url, 'source_id' => source.id, 'requested_by' => staff.id }
  end
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: bridge, message_type: :outgoing,
                     content: "Top\nBlack / S\n#{url}", content_attributes: { 'umi_product_card' => card })
  end

  before do
    allow(SendReplyJob).to receive(:perform_later)
    ENV['UMI_COMMERCE_BRIDGE_USER_ID'] = bridge.id.to_s
    ENV['UMI_COMMERCE_ACCOUNT_ID'] = account.id.to_s
    ENV['UMI_COMMERCE_CLOUD_INBOX_ID'] = channel.inbox.id.to_s
  end

  around do |example|
    with_modified_env UMI_COMMERCE_BRIDGE_USER_ID: nil, UMI_COMMERCE_ACCOUNT_ID: nil,
                      UMI_COMMERCE_CLOUD_INBOX_ID: nil, UMI_PRODUCT_SHARES_CLOUD_ENABLED: nil do
      example.run
    end
  end

  it 'holds by default and never falls through to the ordinary text sender' do
    provider = channel.provider_service
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider)
    allow(provider).to receive(:send_product_share)
    Whatsapp::SendOnWhatsappService.new(message: message).perform
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
    expect(provider).not_to have_received(:send_product_share)
  end

  it 'sends one attributed Cloud image share only inside the reply window, then suppresses duplicate jobs' do
    provider = channel.provider_service
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider)
    allow(provider).to receive(:send_product_share).and_return('message_id' => 'wamid.share')
    with_modified_env UMI_PRODUCT_SHARES_CLOUD_ENABLED: 'true' do
      2.times { Whatsapp::SendOnWhatsappService.new(message: message).perform }
    end
    expect(message.reload.source_id).to eq('wamid.share')
    expect(message.content_attributes.dig('umi_product_delivery', 'state')).to eq('accepted')
    expect(provider).to have_received(:send_product_share).once
  end

  it 'holds when the WhatsApp session has expired' do
    incoming.update!(created_at: 25.hours.ago)
    provider = channel.provider_service
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider)
    allow(provider).to receive(:send_product_share)
    with_modified_env UMI_PRODUCT_SHARES_CLOUD_ENABLED: 'true' do
      Whatsapp::SendOnWhatsappService.new(message: message).perform
    end
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('held')
    expect(provider).not_to have_received(:send_product_share)
  end

  it 'uses one Cloud image request with the attributed URL in its caption' do
    service = channel.provider_service
    requests = []
    allow(HTTParty).to receive(:post) do |_url, options|
      requests << JSON.parse(options.fetch(:body))
      instance_double(HTTParty::Response, success?: true, parsed_response: { 'messages' => [{ 'id' => 'wamid.share' }] })
    end
    expect(service.send_product_share('66123456789', message)).to eq('message_id' => 'wamid.share')
    expect(requests.last['type']).to eq('image')
    expect(requests.last.fetch('image')).to include('link' => card['image_url'])
    expect(requests.last.dig('image', 'caption')).to include(url)
    expect(requests.length).to eq(1)
  end

  it 'uses one text request with the attributed URL when the image is unavailable' do
    message.update!(content_attributes: { 'umi_product_card' => card.except('image_url') })
    service = channel.provider_service
    requests = []
    allow(HTTParty).to receive(:post) do |_url, options|
      requests << JSON.parse(options.fetch(:body))
      instance_double(HTTParty::Response, success?: true, parsed_response: { 'messages' => [{ 'id' => 'wamid.share' }] })
    end
    expect(service.send_product_share('66123456789', message)).to eq('message_id' => 'wamid.share')
    expect(requests.last['type']).to eq('text')
    expect(requests.last.dig('text', 'body')).to include(url)
    expect(requests.length).to eq(1)
  end

  [
    ['rejection', false, { 'error' => { 'message' => 'Denied', 'code' => 10 } }, 'rejected'],
    ['missing message ID', true, { 'messages' => [] }, 'ambiguous'],
    ['malformed response', false, '<html>Unavailable</html>', 'ambiguous']
  ].each do |description, success, payload, expected|
    it "records #{description} through the actual Cloud adapter without replaying the request" do
      allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: success, parsed_response: payload))
      with_modified_env UMI_PRODUCT_SHARES_CLOUD_ENABLED: 'true' do
        2.times { Whatsapp::SendOnWhatsappService.new(message: message).perform }
      end
      expect(HTTParty).to have_received(:post).once
      expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq(expected)
      expect(message.status).to eq('failed')
      expect(message.source_id).to be_nil
    end
  end

  it 'does not replay a Cloud HTTP timeout whose acceptance cannot be known' do
    allow(HTTParty).to receive(:post).and_raise(Net::ReadTimeout)
    with_modified_env UMI_PRODUCT_SHARES_CLOUD_ENABLED: 'true' do
      2.times { Whatsapp::SendOnWhatsappService.new(message: message).perform }
    end
    expect(HTTParty).to have_received(:post).once
    expect(message.reload.content_attributes.dig('umi_product_delivery', 'state')).to eq('ambiguous')
    expect(message.status).to eq('failed')
  end
end
