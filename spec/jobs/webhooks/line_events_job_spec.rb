require 'rails_helper'

RSpec.describe Webhooks::LineEventsJob do
  subject(:job) { described_class.perform_later(params: params) }

  let!(:line_channel) { create(:channel_line, line_channel_id: Umi::Line::DualConsumer::TARGET_CHANNEL_ID) }
  let!(:params) { { :line_channel_id => line_channel.line_channel_id, 'line' => { test: 'test' } } }
  let(:post_body) { params.to_json }
  let(:signature) { Base64.strict_encode64(OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), line_channel.line_channel_secret, post_body)) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(params: params)
      .on_queue('default')
  end

  context 'when invalid params' do
    it 'returns nil when no line_channel_id' do
      expect(described_class.perform_now(params: {})).to be_nil
    end

    it 'returns nil when invalid bot_token' do
      expect(described_class.perform_now(params: { 'line_channel_id' => 'invalid_id', 'line' => { test: 'test' } })).to be_nil
    end
  end

  context 'when valid params' do
    it 'calls Line::IncomingMessageService' do
      process_service = double
      allow(Line::IncomingMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)
      expect(Line::IncomingMessageService).to receive(:new).with(inbox: line_channel.inbox,
                                                                 params: params['line'].with_indifferent_access)
      expect(process_service).to receive(:perform)
      described_class.perform_now(params: params, post_body: post_body, signature: signature)
    end

    context 'when Lumo forwarding is enabled for the target channel' do
      around do |example|
        with_modified_env(
          'UMI_LINE_DUAL_CONSUMER_ENABLED' => 'true',
          'UMI_LINE_LUMO_WEBHOOK_URL' => 'https://lumo.example.test/webhooks/line',
          'UMI_LINE_DUAL_CONSUMER_CHANNEL_ID' => Umi::Line::DualConsumer::TARGET_CHANNEL_ID
        ) { example.run }
      end

      it 'forwards only after validation and still processes the inbound message' do
        allow(Umi::Line::ForwardEventsJob).to receive(:perform_later).and_return(instance_double(Umi::Line::ForwardEventsJob))
        process_service = instance_double(Line::IncomingMessageService, perform: nil)
        allow(Line::IncomingMessageService).to receive(:new).and_return(process_service)

        expect(Umi::Line::ForwardEventsJob).to receive(:perform_later).with(
          post_body: post_body,
          signature: signature,
          line_channel_id: line_channel.line_channel_id
        )
        expect(process_service).to receive(:perform)

        described_class.perform_now(params: params, post_body: post_body, signature: signature)
      end

      it 'continues Chatwoot processing when forwarding enqueue fails' do
        allow(Umi::Line::ForwardEventsJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'queue unavailable')
        process_service = instance_double(Line::IncomingMessageService, perform: nil)
        allow(Line::IncomingMessageService).to receive(:new).and_return(process_service)

        expect(process_service).to receive(:perform)

        expect do
          described_class.perform_now(params: params, post_body: post_body, signature: signature)
        end.not_to raise_error
      end

      it 'continues Chatwoot processing when enqueue returns false' do
        allow(Umi::Line::ForwardEventsJob).to receive(:perform_later).and_return(false)
        process_service = instance_double(Line::IncomingMessageService, perform: nil)
        allow(Line::IncomingMessageService).to receive(:new).and_return(process_service)

        expect(process_service).to receive(:perform)

        described_class.perform_now(params: params, post_body: post_body, signature: signature)
      end

      it 'does not forward an invalid signature' do
        expect(Umi::Line::ForwardEventsJob).not_to receive(:perform_later)

        described_class.perform_now(params: params, post_body: post_body, signature: 'invalid-signature')
      end

      it 'does not forward an unknown channel' do
        unknown_params = params.merge(line_channel_id: 'unknown-line-channel')

        expect(Umi::Line::ForwardEventsJob).not_to receive(:perform_later)

        described_class.perform_now(params: unknown_params, post_body: unknown_params.to_json, signature: signature)
      end
    end

    it 'does not forward when the feature is unconfigured' do
      with_modified_env(
        'UMI_LINE_DUAL_CONSUMER_ENABLED' => nil,
        'UMI_LINE_LUMO_WEBHOOK_URL' => nil,
        'UMI_LINE_DUAL_CONSUMER_CHANNEL_ID' => nil
      ) do
        expect(Umi::Line::ForwardEventsJob).not_to receive(:perform_later)
        described_class.perform_now(params: params, post_body: post_body, signature: signature)
      end
    end

    it 'does not forward a valid event from another LINE channel' do
      other_channel = create(:channel_line)
      other_params = params.merge(line_channel_id: other_channel.line_channel_id)
      other_post_body = other_params.to_json
      other_signature = Base64.strict_encode64(
        OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), other_channel.line_channel_secret, other_post_body)
      )

      with_modified_env(
        'UMI_LINE_DUAL_CONSUMER_ENABLED' => 'true',
        'UMI_LINE_LUMO_WEBHOOK_URL' => 'https://lumo.example.test/webhooks/line',
        'UMI_LINE_DUAL_CONSUMER_CHANNEL_ID' => Umi::Line::DualConsumer::TARGET_CHANNEL_ID
      ) do
        expect(Umi::Line::ForwardEventsJob).not_to receive(:perform_later)
        described_class.perform_now(params: other_params, post_body: other_post_body, signature: other_signature)
      end
    end

    it 'keeps the upstream line job arguments out of Active Job logs' do
      expect(described_class.log_arguments?).to be(false)
    end
  end
end
