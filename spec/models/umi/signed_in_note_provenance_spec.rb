# frozen_string_literal: true

require 'rails_helper'

# Only a signed-in messages request may mark a note; every other way a message is created (jobs, services, webhooks,
# other controllers) drops any value it carries, and an update can only remove it.
RSpec.describe 'Umi::SignedInNoteProvenance' do
  let(:key) { 'umi_signed_in_sender_id' }
  let(:provenance) { Umi::SignedInNoteProvenance }
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:owner) { create(:user, account: account) }
  let(:agent) { create(:user, account: account) }

  def message(**attributes)
    create(:message, { conversation: conversation, message_type: :outgoing, private: true, sender: owner,
                       content_attributes: { key => owner.id } }.merge(attributes))
  end

  it 'drops the value from every message created outside a signed-in request' do
    contact = conversation.contact

    [message,
     message(private: false),
     message(message_type: :incoming, private: false, sender: contact),
     message(message_type: :activity, private: false, sender: nil)].each do |created|
      expect(created.reload.content_attributes).not_to have_key(key)
    end
  end

  it "marks only a private outgoing note whose sender is the signed-in user, with that user's id" do
    provenance.signed_in_sender(owner.id) do
      expect(message(content_attributes: {}).reload.content_attributes[key]).to eq(owner.id)
      expect(message(content_attributes: { key => agent.id }).reload.content_attributes[key]).to eq(owner.id)
      expect(message(private: false).reload.content_attributes).not_to have_key(key)
      expect(message(sender: agent).reload.content_attributes).not_to have_key(key)
      expect(message(message_type: :activity, private: false, sender: nil).reload.content_attributes).not_to have_key(key)
      expect(message(message_type: :template, sender: owner).reload.content_attributes).not_to have_key(key)
    end
  end

  it 'leaves an unmarked message unchanged and keeps its other attributes' do
    plain = message(content_attributes: { 'external_error' => 'timeout' })

    expect(plain.reload.content_attributes).to eq({ 'external_error' => 'timeout' })
    expect(create(:message, conversation: conversation).reload.content_attributes).to eq({})
  end

  it 'clears the scope when the block raises and restores an outer scope' do
    expect { provenance.signed_in_sender(owner.id) { raise ArgumentError } }.to raise_error(ArgumentError)
    expect(message.reload.content_attributes).not_to have_key(key)

    provenance.signed_in_sender(owner.id) do
      provenance.signed_in_sender(agent.id) { nil }
      expect(message(content_attributes: {}).reload.content_attributes[key]).to eq(owner.id)
    end
  end

  it 'never lets an update add or change the mark, and lets it be removed' do
    unmarked = message
    unmarked.update!(content_attributes: { key => owner.id })
    expect(unmarked.reload.content_attributes).not_to have_key(key)

    marked = provenance.signed_in_sender(owner.id) { message }
    marked.update!(content_attributes: marked.content_attributes.merge(key => agent.id, 'translations' => { 'en' => 'x' }))
    expect(marked.reload.content_attributes).to eq({ key => owner.id, 'translations' => { 'en' => 'x' } })

    marked.update!(content_attributes: { 'deleted' => true })
    expect(marked.reload.content_attributes).to eq({ 'deleted' => true })
  end
end
