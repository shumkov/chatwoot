require 'rails_helper'

RSpec.describe 'Webhooks::LineController', type: :request do
  describe 'POST /webhooks/line/{:line_channel_id}' do
    it 'call the line events job with the params' do
      allow(Webhooks::LineEventsJob).to receive(:perform_later)
      expect(Webhooks::LineEventsJob).to receive(:perform_later)
      post '/webhooks/line/line_channel_id', params: { content: 'hello' }
      expect(response).to have_http_status(:success)
    end

    it 'passes the raw request body and signature unchanged to the job' do
      raw_body = '{"destination":"U123","events":[{"type":"message","text":"สวัสดี 👋"}]}'
      signature = 'original-line-signature'

      expect(Webhooks::LineEventsJob).to receive(:perform_later).with(
        params: hash_including(line_channel_id: 'line_channel_id'),
        signature: signature,
        post_body: raw_body
      )

      post '/webhooks/line/line_channel_id', params: raw_body, headers: {
        'CONTENT_TYPE' => 'application/json',
        'X-Line-Signature' => signature
      }

      expect(response).to have_http_status(:success)
    end
  end
end
