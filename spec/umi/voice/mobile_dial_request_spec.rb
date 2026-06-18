# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Voice mobile tap-to-call', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user) }
  let!(:channel) { create(:channel_twilio_sms, account: account, messaging_service_sid: nil, phone_number: '+15550009999') }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, name: 'Jane Caller') }
  let(:token) { Umi::Voice.dial_token(contact.id) }

  before do
    create(:account_user, account: account, user: agent, role: :agent)
    channel.update_column(:voice_enabled, true) # rubocop:disable Rails/SkipsModelValidations
    create(:conversation, account: account, inbox: inbox, contact: contact, assignee: agent)
  end

  it 'round-trips the signed dial token and rejects tampering' do
    expect(Umi::Voice.verify_dial_token(token)).to eq(contact.id)
    expect(Umi::Voice.verify_dial_token('garbage--nope')).to be_nil
  end

  it 'shows a confirm page for a valid link' do
    get "/umi/voice/dial/#{token}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Jane Caller')
  end

  it 'rejects a tampered token' do
    get '/umi/voice/dial/not-a-valid-token'
    expect(response).to have_http_status(:forbidden)
  end

  it 'places the call to the conversation assignee on POST' do
    allow(Umi::Voice::OutboundCallBuilder).to receive(:perform!)

    post "/umi/voice/dial/#{token}"

    expect(Umi::Voice::OutboundCallBuilder).to have_received(:perform!).with(hash_including(user: agent, contact: contact))
    expect(response).to have_http_status(:ok)
  end
end
