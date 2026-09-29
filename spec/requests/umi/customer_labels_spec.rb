# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Managed customer labels', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'rejects protected bulk work before enqueue and again when an old queued job executes' do
    body = { type: 'Conversation', ids: [conversation.display_id], labels: { add: ['vip'] } }
    post "/api/v1/accounts/#{account.id}/bulk_actions", params: body, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect do
      BulkActionsJob.perform_now(account: account, user: agent, params: body.with_indifferent_access)
    end.to raise_error(ArgumentError, /managed/)
    expect(conversation.reload.label_list).to be_empty
  end

  it 'applies bulk topic changes and closure from one current label list' do
    Umi::Funnel::CustomerMutation.new(conversation.contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    Umi::Funnel::CustomerProjectionJob.perform_now(conversation.contact_id)
    conversation.reload.update_labels(%w[vip support-refund])
    body = { type: 'Conversation', ids: [conversation.display_id], labels: { add: ['support-exchange'], remove: ['support-refund'] },
             fields: { status: 'resolved' } }
    BulkActionsJob.perform_now(account: account, user: agent, params: body.with_indifferent_access)
    expect(conversation.reload).to be_resolved
    expect(conversation.label_list).to match_array(%w[vip support-exchange])
    expect(Umi::ConversationEvent.where(event_type: 'classification_topics_corrected').sole.payload).to include('removed' => ['support-refund'])
  end

  it 'returns an explicit stale-label error from the ordinary labels API' do
    Umi::Funnel::CustomerMutation.new(conversation.contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    Umi::Funnel::CustomerProjectionJob.perform_now(conversation.contact_id)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/labels", headers: agent.create_new_auth_token,
                                                                                           params: { labels: ['support-refund'] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('Managed labels changed')
    expect(conversation.reload.label_list).to eq(['vip'])
  end

  it 'provisions compatible definitions idempotently and prevents generic deletion' do
    2.times { Umi::Funnel::Configuration.provision!(account) }
    expect(account.labels.count).to eq(22)
    expect(account.custom_attribute_definitions.where(attribute_model: :contact_attribute).count).to eq(8)
    label = account.labels.find_by!(title: 'vip')
    delete "/api/v1/accounts/#{account.id}/labels/#{label.id}", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Label.exists?(label.id)).to be(true)
  end

  it 'rejects an administrator renaming a managed customer field', :aggregate_failures do
    Umi::Funnel::Configuration.provision!(account)
    definition = account.custom_attribute_definitions.find_by!(attribute_key: 'umi_vip')
    original_name = definition.attribute_display_name

    patch "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{definition.id}",
          headers: agent.create_new_auth_token, params: { custom_attribute_definition: { attribute_display_name: 'Changed' } }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(definition.reload.attribute_display_name).to eq(original_name)
  end

  it 'allows an administrator to rename an unrelated native custom field' do
    definition = create(:custom_attribute_definition, account: account, attribute_key: 'native_field', attribute_model: :contact_attribute)

    patch "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{definition.id}",
          headers: agent.create_new_auth_token, params: { custom_attribute_definition: { attribute_display_name: 'Changed' } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(definition.reload.attribute_display_name).to eq('Changed')
  end

  it 'records native topic removal with an incoming watermark in the same transaction' do
    message = create(:message, conversation: conversation, account: account, message_type: :incoming)
    conversation.update_labels(['support-refund'])
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/labels", headers: agent.create_new_auth_token,
                                                                                           params: { labels: ['support-exchange'] }, as: :json
    expect(response).to have_http_status(:success)
    event = Umi::ConversationEvent.where(event_type: 'classification_topics_corrected').sole
    expect(event.payload).to include('removed' => ['support-refund'], 'added' => ['support-exchange'], 'input_message_id' => message.id)
    expect(event.conversion_deliveries).to be_empty
  end

  it 'rolls back native labels when the correction fence cannot be stored' do
    conversation.update_labels(['support-refund'])
    allow(Umi::Funnel::TopicCorrection).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(Umi::ConversationEvent.new))
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/labels", headers: agent.create_new_auth_token,
                                                                                           params: { labels: ['support-exchange'] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload.label_list).to eq(['support-refund'])
    expect(Umi::ConversationEvent.where(event_type: 'classification_topics_corrected')).to be_empty
  end
end
