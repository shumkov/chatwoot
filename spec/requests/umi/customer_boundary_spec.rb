# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer context public boundaries', type: :request do
  let(:account) { create(:account) }
  let(:widget) { create(:channel_widget, account: account) }
  let(:contact) do
    create(:contact, account: account,
                     additional_attributes: { entry_source: 'store',
                                              umi_klaviyo_sync: { roles: { umi_vip: { baseline: 'no', pending: { actor_id: 22 } } } } })
  end
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: widget.inbox) }
  let(:token) { Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: widget.inbox.id }).generate_token }
  let(:headers) { { 'X-Auth-Token' => token } }

  it 'rejects nested pre-chat role forgery before contact identification' do
    post '/api/v1/widget/conversations', headers: headers, as: :json,
                                         params: { website_token: widget.website_token,
                                                   contact: { custom_attributes: { umi_vip: 'yes' } },
                                                   message: { content: 'Hello' } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(contact.reload.custom_attributes).not_to have_key('umi_vip')
  end

  it 'rejects role deletion and technical additional-attribute forgery' do
    post '/api/v1/widget/contact/destroy_custom_attributes', headers: headers, as: :json,
                                                             params: { website_token: widget.website_token, custom_attributes: ['umi_vip'] }
    expect(response).to have_http_status(:unprocessable_entity)
    patch '/api/v1/widget/contact', headers: headers, as: :json,
                                    params: { website_token: widget.website_token, additional_attributes: { umi_klaviyo_sync: {} } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles')).to be_present
  end

  it 'allows normal pre-chat fields and removes internal state from widget message history' do
    patch '/api/v1/widget/contact', headers: headers, as: :json,
                                    params: { website_token: widget.website_token, custom_attributes: { size: 'M' },
                                              additional_attributes: { entry_source: 'product' } }
    expect(response).to have_http_status(:success)
    conversation = create(:conversation, account: account, inbox: widget.inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, :incoming, conversation: conversation, account: account, sender: contact)
    get '/api/v1/widget/messages', headers: headers, params: { website_token: widget.website_token }
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include('umi_klaviyo_sync', 'baseline', 'actor_id')
    expect(response.body).to include('entry_source')
  end

  it 'rejects public contact create and update forgery' do
    api = create(:channel_api, account: account)
    public_inbox = create(:contact_inbox, contact: contact, inbox: api.inbox)
    post "/public/api/v1/inboxes/#{api.identifier}/contacts", as: :json, params: { custom_attributes: { umi_paid_order_count: 2 } }
    expect(response).to have_http_status(:unprocessable_entity)
    patch "/public/api/v1/inboxes/#{api.identifier}/contacts/#{public_inbox.source_id}", as: :json,
                                                                                         params: { custom_attributes: { umi_influencer: 'yes' } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'removes technical snapshots from public message creation and history while keeping ordinary sender context' do
    api = create(:channel_api, account: account)
    public_inbox = create(:contact_inbox, contact: contact, inbox: api.inbox)
    conversation = create(:conversation, account: account, inbox: api.inbox, contact: contact, contact_inbox: public_inbox)
    path = "/public/api/v1/inboxes/#{api.identifier}/contacts/#{public_inbox.source_id}/conversations/#{conversation.display_id}/messages"
    post path, params: { content: 'Hello' }, as: :json
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include('umi_klaviyo_sync', 'baseline', 'actor_id')
    get path
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include('umi_klaviyo_sync', 'baseline', 'actor_id')
    expect(response.body).to include('entry_source')
  end

  shared_examples 'customer message visibility' do
    let(:conversation) { create(:conversation, account: account, inbox: message_inbox, contact: contact, contact_inbox: message_contact_inbox) }
    let(:summary) { conversation.messages.where(private: true).first! }

    before do
      with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        Umi::Funnel::CustomerProjectionJob.perform_now(contact.id, conversation.id)
      end
    end

    [true, false].each do |writer_enabled|
      it "rejects private customer summary updates when the writer is #{writer_enabled ? 'enabled' : 'disabled'}" do
        expect(summary.content_attributes).to have_key('umi_customer_summary')
        original_attributes = summary.attributes
        with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: writer_enabled ? account.id.to_s : '' do
          patch "#{message_path}/#{summary.id}", headers: message_headers, params: update_params, as: :json
        end

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include(summary.content.lines.first.strip, 'umi_customer_summary')
        expect(summary.reload.attributes).to eq(original_attributes)
      end
    end

    it 'rejects internal activity updates' do
      activity = create(:message, account: account, conversation: conversation, message_type: :activity, content: 'Internal activity')
      patch "#{message_path}/#{activity.id}", headers: message_headers, params: update_params, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(activity.content)
    end

    it 'preserves staff access to the private customer summary' do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: message_inbox, user: agent)
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages", headers: agent.create_new_auth_token

      expect(response).to have_http_status(:success)
      note = response.parsed_body.fetch('payload').find { |message| message['id'] == summary.id }
      expect(note).to include('content' => summary.content, 'private' => true)
    end
  end

  describe 'public inbox message updates' do
    let(:api) { create(:channel_api, account: account) }
    let(:message_inbox) { api.inbox }
    let(:message_contact_inbox) { create(:contact_inbox, contact: contact, inbox: message_inbox) }
    let(:message_path) do
      "/public/api/v1/inboxes/#{api.identifier}/contacts/#{message_contact_inbox.source_id}/conversations/#{conversation.display_id}/messages"
    end
    let(:message_headers) { {} }
    let(:update_params) { {} }

    before do
      # Match production error responses instead of test-mode source excerpts.
      allow(Rails.application).to receive(:env_config).and_return(
        Rails.application.env_config.merge('action_dispatch.show_detailed_exceptions' => false)
      )
    end

    it_behaves_like 'customer message visibility'
  end

  describe 'widget message updates' do
    let(:message_inbox) { widget.inbox }
    let(:message_contact_inbox) { contact_inbox }
    let(:message_path) { '/api/v1/widget/messages' }
    let(:message_headers) { headers }
    let(:update_params) { { website_token: widget.website_token, message: { submitted_values: [{ title: 'test' }] } } }

    it_behaves_like 'customer message visibility'

    it 'updates a public input in an earlier visitor conversation' do
      conversation = create(:conversation, account: account, inbox: widget.inbox, contact: contact, contact_inbox: contact_inbox)
      message = create(:message, account: account, conversation: conversation, content_type: :input_select,
                                 content_attributes: { items: [{ title: 'test', value: 'test' }] })
      create(:conversation, account: account, inbox: widget.inbox, contact: contact, contact_inbox: contact_inbox)
      patch "#{message_path}/#{message.id}", headers: message_headers, params: update_params, as: :json

      expect(response).to have_http_status(:success)
      expect(message.reload.content_attributes.fetch('submitted_values')).to eq([{ 'title' => 'test' }])
    end
  end

  it 'filters customer broadcasts while preserving the same staff payload' do
    agent = create(:user, account: account)
    listener = ActionCableListener.instance
    data = { sender: contact.push_event_data, additional_attributes: { umi_customer_projection: { revision: 8 } } }
    clear_enqueued_jobs
    listener.send(:broadcast, account, [agent.pubsub_token, contact_inbox.pubsub_token], 'message.created', data)
    jobs = enqueued_jobs.select { |job| job[:job] == ActionCableBroadcastJob && job[:args][1] == 'message.created' }
    staff = jobs.find { |job| job[:args][0].include?(agent.pubsub_token) }
    customer = jobs.find { |job| job[:args][0].include?(contact_inbox.pubsub_token) }
    expect(staff[:args][2].to_json).to include('umi_klaviyo_sync', 'umi_customer_projection')
    expect(customer[:args][2].to_json).not_to include('umi_klaviyo_sync', 'umi_customer_projection', 'baseline', 'actor_id')
    expect(customer[:args][2].to_json).to include('entry_source')
  end
end
