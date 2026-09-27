# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Funnel operator status', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes" }
  let(:message) { create(:message, :incoming, account: account, conversation: conversation, created_at: 1.hour.ago) }

  before { create(:inbox_member, user: agent, inbox: conversation.inbox) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601 do
      example.run
    end
  end

  it 'records an explicit sidebar qualification from the latest live incoming evidence only once' do
    message
    create(:message, :incoming, account: account, conversation: conversation, content_attributes: { umi_recovered: true })
    create(:message, account: account, conversation: conversation, message_type: :outgoing)
    create(:message, account: account, conversation: conversation, message_type: :outgoing, private: true)
    params = { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'qualified', size: 'M' } }
    2.times { post path, headers: agent.create_new_auth_token, params: params, as: :json }

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['custom_attributes']).to include('umi_sales_status' => 'qualified', 'size' => 'M')
    expect(conversation.reload.label_list).to include('lead-qualified')
    event = Umi::ConversationEvent.find_by!(conversation_id: conversation.id, event_type: 'conversation_qualified')
    expect(event.evidence_message_ids).to eq([message.id])
    expect(event.occurred_at.to_i).to eq(message.created_at.to_i)
    expect(Umi::ConversationEvent.where(conversation_id: conversation.id, event_type: 'classification_changed').count).to eq(1)
  end

  it 'preserves current human status when another field carries a stale status value' do
    conversation.project_umi_sales_status!('not_sales')
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'size', custom_attributes: { umi_sales_status: 'qualified', size: 'M' } }, as: :json

    expect(response).to have_http_status(:success)
    expect(conversation.reload.custom_attributes).to include('umi_sales_status' => 'not_sales', 'size' => 'M')
    expect(Umi::ConversationEvent.where(conversation_id: conversation.id, event_type: 'classification_changed')).to be_empty
  end

  it 'does not treat an unmarked API hash as an explicit confirmation' do
    conversation.project_umi_sales_status!('engaged')
    post path, headers: agent.create_new_auth_token,
               params: { custom_attributes: { umi_sales_status: 'qualified', size: 'S' } }, as: :json

    expect(response).to have_http_status(:success)
    expect(conversation.reload.custom_attributes).to include('umi_sales_status' => 'engaged', 'size' => 'S')
  end

  it 'rejects qualification without live evidence and does not partially save other fields' do
    create(:message, :incoming, account: account, conversation: conversation, content_attributes: { umi_recovered: true })
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'qualified', size: 'M' } }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq('Qualification requires live incoming evidence')
    expect(conversation.reload.custom_attributes).to eq({})
  end

  it 'rejects an explicit deletion of the managed status' do
    conversation.project_umi_sales_status!('engaged')
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: {} }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('engaged')
  end

  %w[order_placed purchased].each do |status|
    it "cannot manufacture #{status} through the sidebar" do
      post path, headers: agent.create_new_auth_token,
                 params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: status } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.reload.custom_attributes).to eq({})
    end
  end

  it 'rejects stale explicit human edits after Shopify has projected a paid status' do
    message
    conversation.project_umi_sales_status!('purchased')
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'qualified' } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('purchased')
  end

  it 'allows an ordinary attribute edit without overwriting a newer commerce status' do
    conversation.project_umi_sales_status!('purchased')
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'size', custom_attributes: { umi_sales_status: 'qualified', size: 'M' } }, as: :json
    expect(response).to have_http_status(:success)
    expect(conversation.reload.custom_attributes).to include('umi_sales_status' => 'purchased', 'size' => 'M')
  end

  it 'rejects classification of an erased contact' do
    conversation.contact.update!(additional_attributes: { umi_profile_redacted: true })
    post path, headers: agent.create_new_auth_token,
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'engaged' } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload.custom_attributes).to eq({})
  end

  it 'does not grant a bot the staff classification path' do
    bot = create(:agent_bot, account: account)
    create(:agent_bot_inbox, agent_bot: bot, inbox: conversation.inbox)
    post path, headers: { api_access_token: bot.access_token.token },
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'engaged' } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload.custom_attributes).to eq({})
  end

  it 'retains ordinary account authorization' do
    other = create(:user, account: create(:account))
    post path, headers: other.create_new_auth_token,
               params: { changed_attribute_key: 'umi_sales_status', custom_attributes: { umi_sales_status: 'engaged' } }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(conversation.reload.custom_attributes).to eq({})
  end
end
