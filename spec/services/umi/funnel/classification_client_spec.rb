# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::ClassificationClient do
  around do |example|
    with_modified_env UMI_FUNNEL_CLASSIFIER_API_KEY: 'synthetic', UMI_FUNNEL_CLASSIFIER_API_BASE: 'https://proxy.example.test/v1',
                      UMI_FUNNEL_CLASSIFIER_MODEL: 'gpt-6-sol', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500000' do
      example.run
    end
  end

  it 'avoids the OpenAI uniqueItems schema rejection while retaining strict output and bounded requests' do
    original_key = RubyLLM.config.openai_api_key
    request = stub_request(:post, 'https://proxy.example.test/v1/chat/completions').with do |http|
      body = JSON.parse(http.body)
      %w[topics roles].each do |field|
        evidence = body.dig('response_format', 'json_schema', 'schema', 'properties', field, 'items', 'properties', 'evidence_message_ids')
        expect(evidence).to include('type' => 'array', 'minItems' => 1)
        expect(evidence).not_to have_key('uniqueItems')
      end
      body['model'] == 'gpt-6-sol' && body['max_completion_tokens'] == 2048 && !body.key?('tools') &&
        body.dig('response_format', 'json_schema', 'strict') == true && body['messages'].last['content'].include?('Hello')
    end.to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: {
      id: 'synthetic', object: 'chat.completion', model: 'gpt-6-sol',
      choices: [{ index: 0, message: { role: 'assistant', content: { status: 'engaged', topics: [], reason: 'Greeting',
                                                                     evidence_message_ids: [1] }.to_json }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
    }.to_json)

    expect(described_class.new.classify(messages: [{ id: 1, text: 'Hello' }])).to include('status' => 'engaged')
    expect(request).to have_been_requested.once
    expect(RubyLLM.config.openai_api_key).to eq(original_key)
  end

  %w[status topics roles].each do |field|
    it "rejects duplicate #{field} evidence locally even though the provider cannot enforce uniqueness" do
      decision = { 'status' => 'engaged', 'topics' => [], 'roles' => [], 'reason' => 'Greeting', 'evidence_message_ids' => [1] }
      if field == 'status'
        decision['evidence_message_ids'] = [1, 1]
      else
        key, value = field == 'topics' ? %w[label intent-product-details] : %w[role umi_influencer]
        decision[field] = [{ key => value, 'evidence_message_ids' => [1, 1] }]
      end

      expect { described_class.validate!(decision, incoming_ids: [1], fresh_evidence_ids: [1]) }
        .to raise_error(described_class::InvalidDecision)
    end
  end

  it 'does not retry a timed-out inference' do
    request = stub_request(:post, 'https://proxy.example.test/v1/chat/completions').to_timeout
    expect { described_class.new.classify(messages: []) }.to raise_error(StandardError)
    expect(request).to have_been_requested.once
  end

  it 'measures the complete serialized provider body including wrappers and multilingual escaping' do
    input = { messages: [{ id: 1, text: "สวัสดี</script>\nhello" }] }
    observed = nil
    stub_request(:post, 'https://proxy.example.test/v1/chat/completions').with do |http|
      observed = http.body.bytesize
      true
    end.to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: {
      id: 'synthetic', object: 'chat.completion', model: 'gpt-6-sol',
      choices: [{ index: 0, message: { role: 'assistant', content: '{}' }, finish_reason: 'stop' }]
    }.to_json)
    measured = described_class.request_bytes(input)
    described_class.new.classify(input)
    expect(measured).to eq(observed)
  end
end
