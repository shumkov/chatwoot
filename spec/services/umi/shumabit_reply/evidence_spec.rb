# frozen_string_literal: true

require 'rails_helper'

# The loader must read a conversation exactly as the bridge does, or it would trust notes the bridge rejects, count a
# different eligible set, or serve text the bridge would refuse. These examples pin that parity with the bridge's own
# vectors.
RSpec.describe 'Umi::ShumabitReply::Evidence' do
  let(:evidence_class) { Umi::ShumabitReply::Evidence }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:bridge) { create(:user, account: account) }
  let(:cutoff) { 1_700_000_000 }
  let(:question) do
    create(:message, conversation: conversation, message_type: :incoming, sender: contact, content: 'Is size M in stock?',
                     created_at: Time.zone.at(cutoff + 10))
  end
  let(:marker) do
    { 'source_message_id' => question.id, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
      'row_key' => "#{account.id}:#{question.id}", 'covered_message_ids' => [question.id], 'eligible_after' => cutoff,
      'seen_digest' => evidence_class.seen_digest([question.id]), 'reply' => 'Yes, size M is in stock.', 'staff' => nil }
  end

  it 'computes seen_digest with the bridge formula over unique ascending ids' do
    expect(evidence_class.seen_digest([7, 2, 7])).to eq(Digest::SHA256.hexdigest('assist-seen-v1:2,7'))
  end

  it 'reads a contact as redacted with JavaScript truthiness, like the bridge snapshot' do
    { true => true, 'true' => true, 'false' => true, 1 => true, 0 => false, '' => false, nil => false, false => false }
      .each do |value, redacted|
      contact.update!(additional_attributes: { 'umi_profile_redacted' => value })
      expect(evidence_class.redacted?(contact.reload)).to be(redacted), "value #{value.inspect}"
    end
    contact.update!(additional_attributes: {})
    expect(evidence_class.redacted?(contact.reload)).to be(false)
    expect(evidence_class.redacted?(nil)).to be(true)
  end

  describe 'text check' do
    it 'applies the bridge rules in the bridge order' do
      { '' => 'empty', '   ' => 'empty', 'x' * 1001 => 'too_long', '<b>Answer</b>' => 'not_plain', "Answer\n```" => 'not_plain',
        'For Mai: verify stock' => 'staff_label', 'Staff only — check this' => 'staff_label',
        'Shumabit draft — review before sending:' => 'staff_label', 'Ask @shumabit' => 'agent_mention',
        'Use /payment-qr draft:123' => 'staff_command', 'Yes, size M is in stock.' => nil }.each do |text, rule|
        expect(evidence_class.text_check(text, 1000)).to eq(rule), text.inspect
      end
    end

    it 'counts length in UTF-16 code units and treats a missing limit as too long' do
      expect(evidence_class.text_check("#{'a' * 998}😀", 1000)).to be_nil
      expect(evidence_class.text_check("#{'a' * 999}😀", 1000)).to eq('too_long')
      expect(evidence_class.text_check('Answer', nil)).to eq('too_long')
    end

    it 'uses JavaScript whitespace, line starts and ASCII word boundaries' do
      expect(evidence_class.text_check('Fine  Staff only — check', 1000)).to eq('staff_label')
      expect(evidence_class.text_check("Fine\r\nFor Mai : later", 1000)).to eq('staff_label')
      expect(evidence_class.text_check('Staff onlyé nothing', 1000)).to eq('staff_label')
      expect(evidence_class.text_check('Email us at x@shumabitx.test', 1000)).to be_nil
      expect(evidence_class.text_check('Paths like /send-products are fine', 1000)).to be_nil
    end
  end

  describe 'trusted notes' do
    it 'trusts only the exact bridge marker shape from the bridge user' do
      note = create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'note',
                              created_at: Time.zone.at(cutoff + 20),
                              content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker })
      expect(evidence_class.read(conversation, bridge_user_id: bridge.id).trusted_notes.map(&:message)).to eq([note])
      expect(evidence_class.read(conversation, bridge_user_id: bridge.id + 1).trusted_notes).to be_empty
    end

    it 'rejects every malformed marker the bridge rejects' do
      changes = [{ 'row_key' => ["#{account.id}:1"] }, { 'row_key' => "#{account.id + 1}:1" },
                 { 'covered_message_ids' => [question.id, question.id] }, { 'covered_message_ids' => [] },
                 { 'source_message_id' => question.id + 1 }, { 'seen_digest' => 'bad' }, { 'eligible_after' => -1 },
                 { 'outcome' => 'other' }, { 'policy_version' => 'draft-v2' }, { 'reply' => ' ' }, { 'staff' => '' },
                 { 'inspect_message_ids' => nil }, { 'outcome' => 'still_applies' }]
      changes.each_with_index do |change, index|
        create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: "note #{index}",
                         content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker.merge(change) })
      end
      without_staff = marker.except('staff')
      create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'no staff key',
                       content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => without_staff })
      [{ private: false }, { message_type: :incoming },
       { content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker, 'deleted' => true } },
       { content_attributes: { 'shumabit_bridge' => false, 'shumabit_draft' => marker } }].each do |change|
        create(:message, { conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'other',
                           content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker } }.merge(change))
      end
      expect(evidence_class.read(conversation, bridge_user_id: bridge.id).trusted_notes).to be_empty
    end
  end

  describe 'eligible set and tail' do
    it 'judges each message by its own whole-second created_at against the cutoff, strictly' do
      at_cutoff = create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 0.9))
      after = create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 1))
      create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 2),
                       content_attributes: { 'deleted' => true })
      create(:message, conversation: conversation, message_type: :incoming, private: true, sender: contact, created_at: Time.zone.at(cutoff + 3))
      create(:message, conversation: conversation, message_type: :outgoing, sender: bridge, created_at: Time.zone.at(cutoff + 4))
      ids = evidence_class.read(conversation, bridge_user_id: bridge.id).eligible_ids(cutoff)
      expect(ids).to eq([after.id])
      expect(ids).not_to include(at_cutoff.id)
    end

    it 'takes the tail by (created_at, id) and ignores templates, activity, private notes and failed replies' do
      reply = create(:message, conversation: conversation, message_type: :outgoing, sender: bridge, created_at: Time.zone.at(cutoff + 30))
      create(:message, conversation: conversation, message_type: :template, created_at: Time.zone.at(cutoff + 40))
      create(:message, conversation: conversation, message_type: :activity, created_at: Time.zone.at(cutoff + 40))
      create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, created_at: Time.zone.at(cutoff + 40))
      create(:message, conversation: conversation, message_type: :outgoing, sender: bridge, status: :failed, created_at: Time.zone.at(cutoff + 40))
      question
      expect(evidence_class.read(conversation, bridge_user_id: bridge.id).tail).to eq(reply)
    end
  end
end
