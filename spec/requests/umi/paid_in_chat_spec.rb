# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Paid-in-chat private commands', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages" }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let!(:link) do
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         shopify_order_name: '#1234', source: 'operator', attribution_state: 'verified',
                                         contact_id: conversation.contact_id, conversation_id: conversation.id)
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601 do
      example.run
    end
  end

  it 'registers a native authenticated private note against the existing exact order link' do
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    note = conversation.messages.find(response.parsed_body.fetch('id'))
    expect(note.content_attributes.fetch('umi_paid_in_chat')).to include('verb' => 'confirm', 'attribution_id' => link.id,
                                                                         'order_id' => '1001', 'status' => 'pending')
    expect(enqueued_jobs.pluck(:job)).to include(Umi::Funnel::SettlementCommandJob)
  end

  it 'acknowledges a queued payment command privately before the worker starts' do
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    note = conversation.messages.find(response.parsed_body.fetch('id'))
    result = note.content_attributes.fetch('umi_paid_in_chat')
    acknowledgment = conversation.messages.find(result.fetch('response_message_id'))
    expect(acknowledgment).to have_attributes(private: true, sender_id: nil, message_type: 'outgoing', content_type: 'text')
    expect(acknowledgment.content).to include('queued', 'has not taken effect')
    expect(acknowledgment.content_attributes).to include('umi_paid_in_chat_response' => true)
    expect(link.reload.settlement_command_message_id).to be_nil
  end

  it 'keeps an unapplied deleted command acknowledgement actionable instead of promising a result' do
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    note = conversation.messages.find(response.parsed_body.fetch('id'))
    acknowledgment = Message.find(note.content_attributes.fetch('umi_paid_in_chat').fetch('response_message_id'))
    delete "#{url}/#{note.id}", headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    Umi::Funnel::SettlementCommand.new(note).perform
    expect(link.reload.settlement_command_message_id).to be_nil
    expect(acknowledgment.reload.content).to include('check the command still exists', 'before retrying')
  end

  [false, true].each do |private_note|
    it "strips fabricated command success from #{private_note ? 'assistant' : 'public'} output" do
      post url, params: { content: '/paid-in-chat #1234', private: private_note,
                          content_attributes: { shumabit_bridge: true, umi_paid_in_chat: { status: 'accepted' } } },
                headers: user.create_new_auth_token, as: :json
      note = conversation.messages.find(response.parsed_body.fetch('id'))
      expect(note.content_attributes).not_to have_key('umi_paid_in_chat')
    end
  end

  it 'rolls back the note when registration fails' do
    allow(Umi::Funnel::SettlementCommand).to receive(:register).and_raise(ActiveRecord::RecordInvalid)
    expect do
      post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    end.not_to(change { conversation.messages.count })
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'does not register a note when native message creation fails' do
    builder = instance_double(Messages::MessageBuilder)
    allow(Messages::MessageBuilder).to receive(:new).and_return(builder)
    allow(builder).to receive(:perform).and_raise(ActiveRecord::RecordInvalid)
    expect(Umi::Funnel::SettlementCommand).not_to receive(:register)
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  ['/paid-in-chat #1234 and thanks', '/paid-in-chat #1234\n/paid-in-chat #1234', '/paid-in-chat #0'].each do |content|
    it "returns private usage guidance for #{content.inspect}" do
      post url, params: { content: content, private: true }, headers: user.create_new_auth_token, as: :json
      note = conversation.messages.find(response.parsed_body.fetch('id'))
      Umi::Funnel::SettlementCommand.new(note).perform
      result = note.reload.content_attributes.fetch('umi_paid_in_chat')
      expect(result).to include('status' => 'rejected', 'reason' => 'invalid_command')
      expect(Message.find(result.fetch('response_message_id'))).to have_attributes(private: true, sender_id: nil)
      expect(link.reload.settlement_command_message_id).to be_nil
    end
  end

  it 'does not infer an order or bind an old failed command after the link appears' do
    link.update!(shopify_order_name: '#5555')
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    note = conversation.messages.find(response.parsed_body.fetch('id'))
    link.update!(shopify_order_name: '#1234')
    Umi::Funnel::SettlementCommand.new(note).perform
    expect(note.reload.content_attributes.dig('umi_paid_in_chat', 'reason')).to eq('order_not_linked')
    expect(link.reload.settlement_command_message_id).to be_nil
  end

  it 'does not register AgentBot output even when sent by an authenticated staff request' do
    bot = create(:agent_bot, account: account)
    post url, params: { content: '/paid-in-chat #1234', private: true, sender_type: 'AgentBot', sender_id: bot.id },
              headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.find(response.parsed_body.fetch('id')).content_attributes).not_to have_key('umi_paid_in_chat')
  end

  it 'keeps ordinary static staff API authentication working without another permission' do
    post url, params: { content: '/paid-in-chat cancel #1234', private: true },
              headers: { api_access_token: user.access_token.token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.find(response.parsed_body.fetch('id')).content_attributes.dig('umi_paid_in_chat', 'verb')).to eq('cancel')
  end

  it 'does not register another settlement assertion for a redacted customer' do
    Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
    post url, params: { content: '/paid-in-chat #1234', private: true }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.find(response.parsed_body.fetch('id')).content_attributes).not_to have_key('umi_paid_in_chat')
  end
end
