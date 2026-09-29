# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('scripts/umi_classifier_review')

RSpec.describe Umi::Funnel::ClassificationReview do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) do
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hello </script><script>alert(1)</script>')
  end
  let(:manifest) do
    { 'samples' => [{ 'sample' => 10, 'conversation_display_id' => conversation.display_id,
                      'corrections' => [{ 'source' => 'operator-feedback', 'text' => 'Regular customer' },
                                        { 'source' => 'browser-draft', 'text' => 'Check this again' }],
                      'old_proposal' => { 'evidence_message_ids' => [1] } }] }
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s, UMI_FUNNEL_CLASSIFIER_MODEL: 'gpt-6-sol',
                      UMI_FUNNEL_CLASSIFIER_API_BASE: 'https://proxy.example.test/v1', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500000' do
      example.run
    end
  end

  it 'exports exact current context without inference or CRM writes and preserves sample identity and every correction' do
    message
    expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
    packet = nil
    expect do
      packet = described_class.export(account_id: account.id, manifest: manifest)
    end.not_to change(Umi::ConversationEvent, :count)
    sample = packet[:samples].sole
    expect(sample).to include(sample: 10, conversation_display_id: conversation.display_id, conversation_id: conversation.id)
    expect(sample[:context][:messages].sole).to include(id: message.id, text: message.content)
    expect(sample[:human_expectations]).to eq(manifest['samples'].sole['corrections'])
    expect(sample[:historical_original]).to eq(manifest['samples'].sole)
    expect(sample[:proposal]).to be_nil
  end

  it 'validates raw review proposals without replacing them with human expectations or applying changes' do
    message
    packet = JSON.parse(described_class.export(account_id: account.id, manifest: manifest).to_json)
    proposal = { 'status' => 'engaged', 'topics' => [], 'roles' => [], 'reason' => 'Greeting', 'evidence_message_ids' => [message.id] }
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(instance_double(Umi::Funnel::ClassificationClient, classify: proposal))
    result = nil
    expect { result = described_class.infer(packet) }.not_to change(Umi::ConversationEvent, :count)
    expect(result['samples'].sole['proposal']).to eq(proposal)
    expect(result['samples'].sole['human_expectations']).to eq(manifest['samples'].sole['corrections'])
    expect(packet['samples'].sole['proposal']).to be_nil
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
  end

  it 'keeps invalid evidence as an explicit failure without leaking provider output' do
    message
    packet = JSON.parse(described_class.export(account_id: account.id, manifest: manifest).to_json)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(instance_double(Umi::Funnel::ClassificationClient,
                                                                                         classify: 'secret malformed output'))
    result = described_class.infer(packet)
    expect(result['samples'].sole).to include('proposal' => nil, 'failure' => 'Umi::Funnel::ClassificationClient::InvalidDecision')
    expect(result.to_json).not_to include('secret malformed output')
  end

  it 'renders customer and model text inert with a distinct packet-scoped draft key and real evidence anchors' do
    message
    packet = JSON.parse(described_class.export(account_id: account.id, manifest: manifest).to_json)
    sample = packet['samples'].sole
    sample['proposal'] = { 'status' => 'engaged', 'topics' => [], 'roles' => [], 'reason' => '</script><script>alert(2)</script>',
                           'evidence_message_ids' => [message.id] }
    html = UmiClassifierReview.render(packet)
    expect(html).not_to include('<script>alert(')
    expect(html).to include('&lt;/script&gt;', "#sample-10-message-#{message.id}", 'Regular customer', 'browser-draft')
    expect(html).not_to include('umi-classifier-assisted-review-20260929')
    expect(html).to include('umi-classifier-review-')
    expect(html.scan('<script>').size).to eq(1)
  end

  it 'writes private new artifacts and refuses to overwrite prior review data' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'packet.json')
      described_class.write_new!(path, { data: 'original' })
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect { described_class.write_new!(path, { data: 'replacement' }) }.to raise_error(Errno::EEXIST)
      expect(JSON.parse(File.read(path))).to eq('data' => 'original')
    end
  end
end
