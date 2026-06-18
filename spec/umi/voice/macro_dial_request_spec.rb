# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Voice macro tap-to-call', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user) }
  let!(:channel) { create(:channel_twilio_sms, account: account, messaging_service_sid: nil, phone_number: '+15550009999') }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15551112222') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, assignee: agent) }

  before do
    create(:account_user, account: account, user: agent, role: :agent)
    channel.update_column(:voice_enabled, true) # rubocop:disable Rails/SkipsModelValidations
  end

  def macro_payload(overrides = {})
    { token: Umi::Voice.macro_secret, id: conversation.display_id, account: { id: account.id } }.merge(overrides)
  end

  it 'rings the assignee + bridges to the contact when the macro webhook fires' do
    allow(Umi::Voice::OutboundCallBuilder).to receive(:perform!)

    post '/umi/voice/macro_dial', params: macro_payload, as: :json

    expect(Umi::Voice::OutboundCallBuilder).to have_received(:perform!)
      .with(hash_including(user: agent, contact: contact, conversation: conversation))
    expect(response).to have_http_status(:ok)
  end

  it 'rejects a request with a bad token' do
    post '/umi/voice/macro_dial', params: macro_payload(token: 'wrong'), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it '404s for an unknown conversation' do
    post '/umi/voice/macro_dial', params: macro_payload(id: 999_999), as: :json
    expect(response).to have_http_status(:not_found)
  end
end
