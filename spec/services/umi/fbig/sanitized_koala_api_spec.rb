require 'rails_helper'

RSpec.describe Umi::Fbig::SanitizedKoalaApi do
  let(:observer) { instance_double(Proc, call: nil) }
  let(:api) { described_class.new('token', usage_observer: observer) }

  it 'raises a sanitized server error without response, debug, or usage secrets' do
    response = Koala::HTTPService::Response.new(
      500,
      JSON.generate(
        'error' => {
          'type' => 'OAuthException',
          'code' => 2,
          'message' => 'secret body',
          'x-fb-debug' => 'secret debug'
        }
      ),
      {
        'x-fb-debug' => 'secret header',
        'x-app-usage' => JSON.generate('call_count' => 12, 'total_time' => 5, 'total_cputime' => 4)
      }
    )
    allow(Koala).to receive(:make_request).and_return(response)

    expect { api.api('/target') }.to raise_error(Koala::Facebook::ServerError) do |error|
      expect(error.http_status).to eq(500)
      expect(error.fb_error_code).to eq(2)
      expect(error.message).not_to include('secret', 'x-app-usage', 'x-fb-debug')
      expect(error.response_body).to eq('')
    end
    expect(observer).to have_received(:call).with(
      Umi::Fbig::SanitizedKoalaApi::Usage.new(maximum_percent: 12, estimated_regain_minutes: nil)
    )
  end

  it 'rejects malformed present usage metadata without logging the raw value' do
    response = Koala::HTTPService::Response.new(
      200,
      '{"id":"target"}',
      { 'x-app-usage' => '{"call_count":"secret"}' }
    )
    allow(Koala).to receive(:make_request).and_return(response)

    expect { api.api('/target') }
      .to raise_error(described_class::UsageMetadataError, 'invalid Meta usage metadata')
  end

  it 'validates but excludes ad-account usage from the aggregate quota maximum' do
    response = Koala::HTTPService::Response.new(
      200,
      '{"id":"target"}',
      {
        'x-app-usage' => JSON.generate('call_count' => 12, 'total_time' => 5, 'total_cputime' => 4),
        'x-ad-account-usage' => JSON.generate('acc_id_util_pct' => 99)
      }
    )
    allow(Koala).to receive(:make_request).and_return(response)

    expect(api.api('/target').body).to eq('{"id":"target"}')
    expect(observer).to have_received(:call).with(
      Umi::Fbig::SanitizedKoalaApi::Usage.new(maximum_percent: 12, estimated_regain_minutes: nil)
    )
  end

  it 'pins every sanitized request to the reviewed Graph API version' do
    response = Koala::HTTPService::Response.new(200, '{"id":"target"}', {})
    expect(Koala).to receive(:make_request)
      .with('/target', hash_including('access_token' => 'token'), 'get', hash_including(api_version: 'v21.0'))
      .and_return(response)

    expect(api.api('/target').body).to eq('{"id":"target"}')
  end
end
