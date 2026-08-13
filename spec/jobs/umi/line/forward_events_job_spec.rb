require 'rails_helper'

RSpec.describe Umi::Line::ForwardEventsJob do
  let(:endpoint) { 'https://example.com/lumo/webhooks/line' }
  let(:raw_body) { '{"destination":"U123","events":[{"type":"message","text":"สวัสดี 👋"}]}' }
  let(:signature) do
    Base64.strict_encode64(OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), 'channel-secret', raw_body))
  end
  let(:arguments) do
    { post_body: raw_body, signature: signature, line_channel_id: '2010611374' }
  end

  around do |example|
    with_modified_env(
      'UMI_LINE_DUAL_CONSUMER_ENABLED' => 'true',
      'UMI_LINE_LUMO_WEBHOOK_URL' => endpoint,
      'UMI_LINE_DUAL_CONSUMER_CHANNEL_ID' => '2010611374'
    ) { example.run }
  end

  it 'forwards the exact body and original signature' do
    forwarded_body = nil
    stub_request(:post, endpoint).with do |request|
      forwarded_body = request.body
      request.headers['X-Line-Signature'] == signature && request.body == raw_body
    end.to_return(status: 204, body: '')

    described_class.new.perform(**arguments)

    expect(WebMock).to have_requested(:post, endpoint).once
    expect(forwarded_body.bytes).to eq(raw_body.bytes)
    expect(Base64.strict_encode64(OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), 'channel-secret', forwarded_body)))
      .to eq(signature)
  end

  it 'does not forward when the kill switch is disabled' do
    stub_request(:post, endpoint).to_return(status: 204, body: '')

    with_modified_env('UMI_LINE_DUAL_CONSUMER_ENABLED' => 'false') do
      described_class.new.perform(**arguments)
    end

    expect(WebMock).not_to have_requested(:post, endpoint)
  end

  it 'does not follow redirects' do
    redirect_endpoint = 'https://example.com/lumo/redirect'
    redirected_endpoint = 'https://example.com/other/webhooks/line'
    stub_request(:post, endpoint).to_return(status: 307, headers: { 'Location' => redirect_endpoint })
    stub_request(:post, redirect_endpoint).to_return(status: 307, headers: { 'Location' => redirected_endpoint })
    stub_request(:post, redirected_endpoint).to_return(status: 204, body: '')

    described_class.new.perform(**arguments)

    expect(WebMock).not_to have_requested(:post, redirect_endpoint)
    expect(WebMock).not_to have_requested(:post, redirected_endpoint)
  end

  it 'logs a transport failure without exposing request data' do
    stub_request(:post, endpoint).to_raise(Net::ReadTimeout)
    warning = nil
    allow(Rails.logger).to receive(:warn) { |message| warning = message }

    expect { described_class.new.perform(**arguments) }.to raise_error(described_class::RetryableError)

    expect(warning).to include('stage=forward_retry')
    expect(warning).not_to include(raw_body, signature, endpoint)
  end

  it 'retries upstream server failures' do
    stub_request(:post, endpoint).to_return(status: 503, body: 'unavailable')
    warning = nil
    allow(Rails.logger).to receive(:warn) { |message| warning = message }

    expect { described_class.new.perform(**arguments) }.to raise_error(described_class::RetryableError)
    expect(warning).to include('stage=forward_retry', 'status=503')
  end

  it 'retries TLS failures without exposing request data' do
    stub_request(:post, endpoint).to_raise(OpenSSL::SSL::SSLError.new('certificate verify failed'))
    warning = nil
    allow(Rails.logger).to receive(:warn) { |message| warning = message }

    expect { described_class.new.perform(**arguments) }.to raise_error(described_class::RetryableError)
    expect(warning).to include('stage=forward_retry', 'SSLError')
    expect(warning).not_to include(raw_body, signature, endpoint)
  end

  it 'retries refused connections' do
    stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED)

    expect { described_class.new.perform(**arguments) }.to raise_error(described_class::RetryableError)
  end
end
