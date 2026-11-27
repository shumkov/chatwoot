# frozen_string_literal: true

require 'rails_helper'

# The login email decides who can recover the account, so changing it needs an interactive sign-in session. A
# request authenticated with an access token may still update every other supported profile field.
RSpec.describe 'Profile email changes need a signed-in session', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, email: 'owner@example.test', name: 'Owner', display_name: 'Owner') }
  let(:token) { { 'api_access_token' => user.access_token.token } }

  def signed_in(headers = {})
    post new_user_session_url, params: { email: user.email, password: 'Password1!' }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    response.headers.slice('access-token', 'client', 'uid')
  end

  def update_profile(headers, **profile)
    patch '/api/v1/profile', params: { profile: profile }, headers: headers, as: :json
  end

  describe 'with an access token' do
    it 'refuses a new email before changing anything in the same request' do
      headers = token
      expect do
        update_profile(headers, email: 'someone-else@example.test', name: 'Renamed', display_name: 'R')
      end.not_to have_enqueued_mail

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => 'email_change_requires_signed_in_session')
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: nil, name: 'Owner', display_name: 'Owner')
    end

    it 'refuses it when signed-in session headers come with the token' do
      update_profile(token.merge(signed_in), email: 'someone-else@example.test')

      expect(response).to have_http_status(:forbidden)
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: nil)
    end

    it 'refuses it on PUT and with the token in its HTTP_ header spelling' do
      put '/api/v1/profile', params: { profile: { email: 'someone-else@example.test' } },
                             headers: { 'HTTP_API_ACCESS_TOKEN' => user.access_token.token }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: nil)
    end

    it 'refuses a blank or null value for the email' do
      ['', nil].each do |email|
        update_profile(token, email: email, name: 'Renamed')
        expect(response).to have_http_status(:forbidden)
      end
      expect(user.reload).to have_attributes(email: 'owner@example.test', name: 'Owner')
    end

    it 'refuses the address of a pending confirmation, and leaves that confirmation as it is' do
      update_profile(signed_in, email: 'pending@example.test')
      pending_token = user.reload.confirmation_token
      expect(user.unconfirmed_email).to eq('pending@example.test')
      headers = token

      expect { update_profile(headers, email: 'pending@example.test') }.not_to have_enqueued_mail

      expect(response).to have_http_status(:forbidden)
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: 'pending@example.test',
                                             confirmation_token: pending_token)
    end

    it 'accepts the current email as native normalisation reads it, with other fields' do
      update_profile(token, email: '  Owner@Example.TEST ', name: 'Renamed')

      expect(response).to have_http_status(:success)
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: nil, name: 'Renamed')
    end

    it 'keeps updating every supported field that is not the email' do
      update_profile(token, name: 'Renamed', display_name: 'R', message_signature: 'Thanks', phone_number: '+66000000000',
                            ui_settings: { 'is_contact_sidebar_open' => true })

      expect(response).to have_http_status(:success)
      expect(user.reload).to have_attributes(name: 'Renamed', display_name: 'R', message_signature: 'Thanks',
                                             email: 'owner@example.test')
      expect(user.custom_attributes['phone_number']).to eq('+66000000000')
      expect(user.ui_settings['is_contact_sidebar_open']).to be(true)
    end
  end

  describe 'from a signed-in session' do
    it 'changes the email as native Chatwoot does, on the web and on the mobile app' do
      update_profile(signed_in, email: 'new@example.test')
      expect(response).to have_http_status(:success)
      expect(user.reload).to have_attributes(email: 'owner@example.test', unconfirmed_email: 'new@example.test')

      mobile = signed_in('X-Chatwoot-Client-Name' => 'Chatwoot Mobile', 'X-Chatwoot-Client-Version' => '4.0.0')
      update_profile(mobile, email: 'newer@example.test')
      expect(response).to have_http_status(:success)
      expect(user.reload.unconfirmed_email).to eq('newer@example.test')
    end
  end
end
