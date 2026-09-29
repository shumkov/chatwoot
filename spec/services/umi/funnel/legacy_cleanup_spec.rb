# rubocop:disable Rails/SkipsModelValidations, RSpec/MultipleExpectations
require 'rails_helper'
require 'tmpdir'

RSpec.describe Umi::Funnel::LegacyCleanup do
  let!(:account) { create(:account, id: 1) }
  let!(:contact) { create(:contact, account: account, custom_attributes: { 'shopify_summary' => 'old', 'keep' => 'yes' }) }
  let!(:conversation) { create(:conversation, account: account, contact: contact, status: :resolved) }
  let(:directory) { Dir.mktmpdir('cleanup') }
  let(:cleanup) { described_class.new(root: directory) }

  before do
    allow(Umi::Funnel::ConversationClassifier).to receive(:mode).and_return('shadow')
    allow(Umi::Funnel::Configuration).to receive(:customer_context_enabled?).and_return(false)
    conversation.update!(label_list: %w[lead-new support-refund])
    create(:label, account: account, title: 'lead-new')
    create(:custom_attribute_definition, account: account, attribute_key: 'shopify_summary', attribute_model: :contact_attribute)
  end

  after { FileUtils.remove_entry(directory) }

  it 'removes retired fields and label cache on resolved chats without touching shared tags or another account' do
    other = create(:conversation, account: create(:account, id: 900))
    other.update!(label_list: ['lead-new'])
    cleanup.inventory
    expect { cleanup.apply }.not_to change(Umi::ConversationEvent, :count)
    expect(contact.reload.custom_attributes).to eq('keep' => 'yes')
    expect(conversation.reload.cached_label_list).to eq('support-refund')
    expect(other.reload.label_list).to include('lead-new')
    expect(ActsAsTaggableOn::Tag.where(name: 'lead-new')).to exist
    expect(account.labels.where(title: 'lead-new')).not_to exist
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).not_to exist
    expect(cleanup.apply[:held]).to eq(0)
  end

  it 'holds a changed preview instead of overwriting operator data' do
    cleanup.inventory
    contact.update_columns(custom_attributes: { 'shopify_summary' => 'changed' })
    expect(cleanup.apply[:held]).to eq(1)
    expect(contact.reload.custom_attributes['shopify_summary']).to eq('changed')
  end

  it 'restores only owned values and preserves subsequent unrelated changes' do
    cleanup.inventory
    cleanup.apply
    contact.update_columns(custom_attributes: { 'keep' => 'new' })
    cleanup.restore
    expect(contact.reload.custom_attributes).to eq('keep' => 'new', 'shopify_summary' => 'old')
    expect(conversation.reload.label_list.sort).to eq(%w[lead-new support-refund])
  end

  it 'never restores erased customer recovery data' do
    cleanup.inventory
    cleanup.apply
    contact.update_columns(additional_attributes: { 'umi_profile_redacted' => true })
    cleanup.restore
    expect(contact.reload.custom_attributes).not_to have_key('shopify_summary')
    expect(Dir.glob(File.join(directory, 'contact-*.json'))).to be_empty
  end

  it 'holds conversations reassigned after the preview' do
    cleanup.inventory
    conversation.update_columns(contact_id: create(:contact, account: account).id)
    expect(cleanup.apply[:held]).to eq(1)
    expect(contact.reload.custom_attributes).to have_key('shopify_summary')
  end

  it 'expires recovery and permanently closes the fixed operation' do
    cleanup.inventory
    travel 31.days do
      cleanup.prune
      expect(Dir.glob(File.join(directory, 'contact-*.json'))).to be_empty
      expect { cleanup.inventory }.to raise_error(ArgumentError, /closed/)
      expect { cleanup.apply }.to raise_error(ArgumentError, /closed/)
    end
  end

  it 'does not delete a definition still referenced by saved filters' do
    create(:custom_filter, account: account, query: { payload: [{ attribute_key: 'shopify_summary' }] })
    cleanup.inventory
    expect { cleanup.apply }.to raise_error(ArgumentError, /references/)
    expect(contact.reload.custom_attributes).to have_key('shopify_summary')
  end

  it 'requires customer writers to be stopped before applying' do
    cleanup.inventory
    allow(Umi::Funnel::Configuration).to receive(:customer_context_enabled?).with(1).and_return(true)
    expect { cleanup.apply }.to raise_error(ArgumentError, /writers/)
  end

  it 'prunes recovery even when all funnel accounts are disabled' do
    allow(described_class).to receive(:new).and_return(cleanup)
    allow(Umi::Funnel::Configuration).to receive(:account_ids).and_return([])
    expect(cleanup).to receive(:prune)
    Umi::Funnel::ReconcileJob.perform_now
  end

  it 'erases recovery files and the unverified private note at customer erasure' do
    cleanup.inventory
    allow(described_class).to receive(:root).and_return(Pathname(directory))
    note = create(:message, conversation: conversation, account: account, private: true,
                            content_attributes: { described_class::NOTE_MARKER => described_class.note_marker(contact) })
    contact.with_lock { Umi::Funnel::Privacy.redact_contact!(contact) }
    expect(Dir.glob(File.join(directory, 'contact-*.json'))).to be_empty
    expect(Message.exists?(note.id)).to be(false)
  end

  it 'preserves the same global label in another tagging context' do
    tag = ActsAsTaggableOn::Tag.find_by!(name: 'lead-new')
    tagging = ActsAsTaggableOn::Tagging.create!(tag: tag, taggable: conversation, context: 'topics')
    cleanup.inventory
    cleanup.apply
    expect(ActsAsTaggableOn::Tagging.exists?(tagging.id)).to be(true)
  end

  it 'holds conditional restore when an operator has replaced a retired value' do
    cleanup.inventory
    cleanup.apply
    contact.update_columns(custom_attributes: { 'shopify_summary' => 'operator' })
    expect(cleanup.restore[:held]).to eq(1)
    expect(contact.reload.custom_attributes['shopify_summary']).to eq('operator')
  end

  it 'keeps recovery files private and does not reapply after explicit restore' do
    cleanup.inventory
    paths = Dir.glob(File.join(directory, '*.json'))
    expect(paths).not_to be_empty
    expect(paths.map { |path| File.stat(path).mode & 0o777 }.uniq).to eq([0o600])
    cleanup.apply
    cleanup.restore
    expect(cleanup.apply[:held]).to eq(1)
  end

  it 'preserves the unmatched legacy customer as an explicitly unverified private note' do
    unmatched = create(:contact, id: 1388, account: account, custom_attributes: { 'shopify_summary' => 'unverified history' })
    chat = create(:conversation, account: account, contact: unmatched)
    cleanup.inventory
    cleanup.apply
    cleanup.apply
    notes = chat.messages.where(private: true).to_a
    expect(notes.size).to eq(1)
    expect(notes.first.content).to include('Unverified legacy Shopify context; not a confirmed customer/order link.')
    expect(notes.first.content_attributes[described_class::NOTE_MARKER]).to eq(described_class.note_marker(unmatched))
    expect(unmatched.reload.additional_attributes).not_to have_key('shopify_customer_id')
  end

  it 'holds catalog deletion if a new legacy record appeared after inventory' do
    cleanup.inventory
    create(:contact, account: account, custom_attributes: { 'shopify_summary' => 'new' })
    expect { cleanup.apply }.to raise_error(ArgumentError, /Unprocessed legacy/)
    expect(account.labels.where(title: 'lead-new')).to exist
  end

  it 'recognizes a committed cleanup when the process lost its final receipt' do
    cleanup.inventory
    cleanup.apply
    path = File.join(directory, "contact-#{contact.id}.json")
    saved = JSON.parse(File.read(path))
    File.write(path, JSON.generate(saved.merge('status' => 'applying')))
    expect(cleanup.apply[:held]).to eq(0)
    expect(JSON.parse(File.read(path))['status']).to eq('applied')
  end

  it 'does not create a new recovery image for an already erased contact' do
    contact.update_columns(additional_attributes: { 'umi_profile_redacted' => true })
    cleanup.inventory
    expect(Dir.glob(File.join(directory, 'contact-*.json'))).to be_empty
  end

  it 'prunes private temporary files left by an interrupted atomic write' do
    cleanup.inventory
    path = File.join(directory, ".contact-#{contact.id}-123-dead.tmp")
    File.write(path, 'private data')
    cleanup.prune
    expect(File.exist?(path)).to be(false)
  end

  it 'does not remove unconfirmed review sentinel fields' do
    contact.update_columns(custom_attributes: { 'review_sentinel' => 'keep', 'shopify_summary' => 'old' })
    cleanup.inventory
    cleanup.apply
    expect(contact.reload.custom_attributes).to eq('review_sentinel' => 'keep')
  end

  it 'does not claim manual clearing after preview as this migration output' do
    cleanup.inventory
    contact.update_columns(custom_attributes: {})
    conversation.update!(label_list: ['support-refund'])
    expect(cleanup.apply[:held]).to eq(1)
  end

  it 'does not restore a definition removed by an operator after inventory' do
    cleanup.inventory
    account.custom_attribute_definitions.find_by!(attribute_key: 'shopify_summary').destroy!
    expect { cleanup.apply }.to raise_error(ArgumentError, /definitions changed/)
    cleanup.restore
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).not_to exist
  end

  it 'erases interrupted private snapshots immediately without removing another contact file' do
    cleanup.inventory
    allow(described_class).to receive(:root).and_return(Pathname(directory))
    interrupted = File.join(directory, ".contact-#{contact.id}-123-dead.tmp")
    other = File.join(directory, ".contact-#{contact.id}9-123-dead.tmp")
    File.write(interrupted, 'private before image')
    File.write(other, 'another contact')
    contact.with_lock { Umi::Funnel::Privacy.redact_contact!(contact) }
    expect(File.exist?(interrupted)).to be(false)
    expect(File.exist?(other)).to be(true)
  end

  it 'erases the original owners unverified snapshot after reassignment and preserves another owners note' do
    source = create(:contact, id: 1388, account: account, custom_attributes: { 'shopify_summary' => 'private source context' })
    chat = create(:conversation, account: account, contact: source)
    cleanup.inventory
    cleanup.apply
    note = chat.messages.where(private: true).first
    other = create(:message, conversation: chat, account: account, private: true,
                             content_attributes: { described_class::NOTE_MARKER => {
                               'migration' => described_class::MIGRATION, 'account_id' => account.id, 'contact_id' => contact.id
                             } })
    chat.update_columns(contact_id: contact.id)
    allow(described_class).to receive(:root).and_return(Pathname(directory))
    source.with_lock { Umi::Funnel::Privacy.redact_contact!(source) }
    expect(Message.exists?(note.id)).to be(false)
    expect(Message.exists?(other.id)).to be(true)
  end

  it 'resumes authorized catalog removal after the database transaction rolled back' do
    cleanup.inventory
    allow(cleanup).to receive(:remove_catalog).and_wrap_original do |method, *args|
      method.call(*args)
      raise 'interrupted before catalog commit'
    end
    expect { cleanup.apply }.to raise_error(/interrupted/)
    expect(account.labels.where(title: 'lead-new')).to exist
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).to exist
    saved = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    expect(saved.dig('catalog', 'status')).to eq('applying')
    allow(cleanup).to receive(:remove_catalog).and_call_original
    cleanup.apply
    expect(account.labels.where(title: 'lead-new')).not_to exist
    cleanup.restore
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).to exist
  end

  it 'recognizes committed catalog removal after its final receipt was lost' do
    cleanup.inventory
    allow(cleanup).to receive(:atomic).and_wrap_original do |method, name, data|
      raise 'interrupted after catalog commit' if name == 'manifest' && data.dig('catalog', 'status') == 'applied'

      method.call(name, data)
    end
    expect { cleanup.apply }.to raise_error(/interrupted/)
    expect(account.labels.where(title: 'lead-new')).not_to exist
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).not_to exist
    saved = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    expect(saved.dig('catalog', 'status')).to eq('applying')
    allow(cleanup).to receive(:atomic).and_call_original
    expect(cleanup.apply[:held]).to eq(0)
    cleanup.restore
    expect(account.labels.where(title: 'lead-new')).to exist
  end

  it 'recognizes committed catalog restore and never reapplies a later operator deletion' do
    cleanup.inventory
    cleanup.apply
    allow(cleanup).to receive(:atomic).and_wrap_original do |method, name, data|
      raise 'interrupted after catalog restore' if name == 'manifest' && data.dig('catalog', 'status') == 'restored'

      method.call(name, data)
    end
    expect { cleanup.restore }.to raise_error(/interrupted/)
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).to exist
    allow(cleanup).to receive(:atomic).and_call_original
    cleanup.restore
    account.custom_attribute_definitions.find_by!(attribute_key: 'shopify_summary').destroy!
    cleanup.restore
    expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).not_to exist
  end

  it 'preserves a newer catalog definition instead of replacing it with the deleted one' do
    cleanup.inventory
    cleanup.apply
    newer = create(:custom_attribute_definition, account: account, attribute_key: 'shopify_summary',
                                                 attribute_model: :contact_attribute, attribute_display_name: 'Operator definition')
    cleanup.restore
    expect(account.custom_attribute_definitions.find_by!(attribute_key: 'shopify_summary').id).to eq(newer.id)
    expect(newer.reload.attribute_display_name).to eq('Operator definition')
  end

  %w[operator_deletion transaction_rollback].each do |interruption|
    it "holds an ambiguous catalog restore after #{interruption} instead of inserting missing entries again" do
      cleanup.inventory
      cleanup.apply
      if interruption == 'operator_deletion'
        allow(cleanup).to receive(:atomic).and_wrap_original do |method, name, data|
          raise 'interrupted after catalog restore' if name == 'manifest' && data.dig('catalog', 'status') == 'restored'

          method.call(name, data)
        end
      else
        allow(cleanup).to receive(:restore_catalog).and_wrap_original do |method, *args|
          method.call(*args)
          raise 'interrupted before catalog restore commit'
        end
      end
      expect { cleanup.restore }.to raise_error(/interrupted/)
      account.custom_attribute_definitions.find_by!(attribute_key: 'shopify_summary').destroy! if interruption == 'operator_deletion'
      allow(cleanup).to receive(:atomic).and_call_original
      allow(cleanup).to receive(:restore_catalog).and_call_original
      expect { cleanup.restore }.to raise_error(ArgumentError, /restore outcome is ambiguous/)
      expect(account.custom_attribute_definitions.where(attribute_key: 'shopify_summary')).not_to exist
      saved = JSON.parse(File.read(File.join(directory, 'manifest.json')))
      expect(saved.dig('catalog', 'status')).to eq('restoring')
    end
  end
  it 'recognizes an unchanged multi-label catalog after a lost restore receipt' do
    create(:label, account: account, title: 'lead-lost')
    cleanup.inventory
    cleanup.apply
    allow(cleanup).to receive(:atomic).and_wrap_original do |method, name, data|
      raise 'interrupted after catalog restore' if name == 'manifest' && data.dig('catalog', 'status') == 'restored'

      method.call(name, data)
    end
    expect { cleanup.restore }.to raise_error(/interrupted/)
    allow(cleanup).to receive(:atomic).and_call_original
    expect(cleanup.restore[:held]).to eq(0)
    expect(account.labels.where(title: %w[lead-new lead-lost]).count).to eq(2)
    saved = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    expect(saved.dig('catalog', 'status')).to eq('restored')
  end
end

# rubocop:enable Rails/SkipsModelValidations, RSpec/MultipleExpectations
