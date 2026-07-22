require 'rails_helper'

describe Umi::FbigTrace do
  describe '.log' do
    it 'writes drop stages as warnings with key=value fields' do
      allow(Rails.logger).to receive(:warn).and_call_original

      described_class.log(:dropped, channel: 'instagram', reason: 'no_channel', instagram_id: 'ig-1')

      expect(Rails.logger).to have_received(:warn)
        .with('[UMI-FBIG] stage=dropped channel=instagram reason=no_channel instagram_id=ig-1')
    end

    it 'never raises out of a logging failure' do
      allow(Rails.logger).to receive(:info).and_raise(IOError)

      expect { described_class.log(:persisted, mid: 'm1') }.not_to raise_error
    end

    it 'is silenced by UMI_FBIG_TRACE_DISABLED' do
      allow(Rails.logger).to receive(:info).and_call_original

      with_modified_env UMI_FBIG_TRACE_DISABLED: 'true' do
        described_class.log(:persisted, mid: 'm1')
      end

      expect(Rails.logger).not_to have_received(:info)
    end
  end

  describe 'Instagram pipeline tracing', type: :request do
    it 'logs a dropped line when no channel matches the webhook instagram_id' do
      allow(Rails.logger).to receive(:warn).and_call_original
      entries = [{
        'id': 'entry-1',
        'time': '2021-09-08T06:34:04+0000',
        'messaging': [{
          'sender': { 'id': 'ig-sender-1' },
          'recipient': { 'id': 'no-such-channel-id' },
          'timestamp': '2021-09-08T06:34:04+0000',
          'message': { 'mid': 'mid-1', 'text': 'hello' }
        }]
      }]

      expect { Webhooks::InstagramEventsJob.perform_now(entries) }.not_to raise_error

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=dropped channel=instagram reason=no_channel instagram_id=no-such-channel-id/))
    end

    it 'logs a rejected line when the webhook signature does not match' do
      allow(Rails.logger).to receive(:warn).and_call_original

      post '/webhooks/instagram', params: { object: 'instagram', entry: [] }.to_json,
                                  headers: { 'Content-Type' => 'application/json', 'X-Hub-Signature-256' => 'sha256=bogus' }

      expect(response).to have_http_status(:unauthorized)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=rejected channel=instagram reason=signature/))
    end
  end

  describe 'Facebook pipeline tracing', type: :request do
    before do
      stub_request(:post, /graph\.facebook\.com/)
    end

    let!(:facebook_channel) { create(:channel_facebook_page) }
    let(:provider) { Facebook::Messenger.config.provider }

    it 'passes a correctly signed webhook through untouched and logs webhook_received' do
      allow(Rails.logger).to receive(:info).and_call_original
      allow(provider).to receive(:app_secret_for).and_return('some-secret')

      body = { object: 'page', entry: [{ id: facebook_channel.page_id, messaging: [] }] }.to_json
      signature = "sha1=#{OpenSSL::HMAC.hexdigest('sha1', 'some-secret', body)}"
      post '/bot', params: body, headers: { 'Content-Type' => 'application/json', 'X-Hub-Signature' => signature }

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:info)
        .with(a_string_matching(/stage=webhook_received channel=facebook entries=1 entry_ids=#{facebook_channel.page_id}/))
    end

    it 'logs a rejected line when the /bot signature check fails' do
      allow(Rails.logger).to receive(:warn).and_call_original
      allow(provider).to receive(:app_secret_for).and_return('some-secret')

      body = { entry: [{ id: facebook_channel.page_id, messaging: [] }] }.to_json
      post '/bot', params: body, headers: { 'Content-Type' => 'application/json', 'X-Hub-Signature' => 'sha1=bogus' }

      expect(response).to have_http_status(:bad_request)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=rejected channel=facebook reason=signature/))
    end

    it 'logs standby entries the gem discards' do
      allow(Rails.logger).to receive(:warn).and_call_original
      allow(provider).to receive(:app_secret_for).and_return(nil)

      body = {
        object: 'page',
        entry: [{ id: facebook_channel.page_id,
                  standby: [{ sender: { id: 'user-1' }, recipient: { id: facebook_channel.page_id },
                              message: { mid: 'standby-mid-1', text: 'hi' } }] }]
      }.to_json
      post '/bot', params: body, headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=dropped channel=facebook reason=standby entry_id=#{facebook_channel.page_id} mids=standby-mid-1/))
    end

    it 'logs a persisted line when an inbound message is stored' do
      allow(Rails.logger).to receive(:info).and_call_original
      fb_object = double
      allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
      allow(fb_object).to receive(:get_object).and_return({ first_name: 'Jane', last_name: 'Dae' }.with_indifferent_access)

      message_object = {
        messaging: {
          sender: { id: 'fb-user-1' },
          recipient: { id: facebook_channel.page_id },
          message: { mid: 'mid-persisted-1', text: 'hello there' }
        }
      }.to_json
      parsed = Integrations::Facebook::MessageParser.new(message_object)
      Messages::Facebook::MessageBuilder.new(parsed, facebook_channel.inbox).perform

      expect(facebook_channel.inbox.messages.count).to eq(1)
      expect(Rails.logger).to have_received(:info)
        .with(a_string_matching(/stage=persisted channel=facebook .*mid=mid-persisted-1 message_id=\d+/))
    end
  end
end
