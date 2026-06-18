# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Voice click-to-call', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user) }
  let!(:channel) { create(:channel_twilio_sms, account: account, messaging_service_sid: nil, phone_number: '+15550009999') }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }

  before do
    create(:account_user, account: account, user: agent, role: :agent)
    channel.update_column(:voice_enabled, true) # rubocop:disable Rails/SkipsModelValidations
  end

  def post_call
    post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/call",
         params: { inbox_id: inbox.id }, headers: agent.create_new_auth_token, as: :json
  end

  context 'when the agent is assigned to the voice-enabled inbox' do
    before { create(:inbox_member, user: agent, inbox: inbox) }

    it 'originates the call and returns the call sid' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
      built = Umi::Call.create!(account: account, inbox: inbox, conversation: conversation, contact: contact,
                                provider: :twilio, direction: :outgoing, provider_call_id: 'CAout', status: 'ringing', accepted_by_agent: agent)
      allow(Umi::Voice::OutboundCallBuilder).to receive(:perform!).and_return(built)

      post_call

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['call_sid']).to eq('CAout')
    end
  end

  it 'rejects an agent not assigned to the inbox (no IDOR)' do
    post_call
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects calling via a voice-disabled inbox' do
    create(:inbox_member, user: agent, inbox: inbox)
    channel.update_column(:voice_enabled, false) # rubocop:disable Rails/SkipsModelValidations

    post_call
    expect(response).to have_http_status(:not_found)
  end
end
