# frozen_string_literal: true

require 'rails_helper'

# The loader only reads: it serves a Shumabit draft that was made with knowledge of exactly the current customer input,
# and otherwise explains, from the bridge's metadata-only status, why there is none. It never asks the bridge or a
# model to make anything.
RSpec.describe 'Umi::ShumabitReply::Loader' do
  let(:evidence_class) { Umi::ShumabitReply::Evidence }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:bridge) { create(:user, account: account) }
  let(:cutoff) { 1_700_000_000 }
  let(:status_url) { 'http://bridge.test/webhook' }
  let(:loader) { Umi::ShumabitReply::Loader }
  let(:config) { Umi::ShumabitReply::Configuration.current }
  let(:question) do
    create(:message, conversation: conversation, message_type: :incoming, sender: contact, content: 'Is size M in stock?',
                     created_at: Time.zone.at(cutoff + 10))
  end

  around do |example|
    with_modified_env(UMI_SHUMABIT_BRIDGE_URL: 'http://bridge.test', UMI_COMMERCE_BRIDGE_USER_ID: bridge.id.to_s) { example.run }
  end

  before do
    # Another account's conversation first, so this conversation's id and display id differ.
    create(:conversation)
    InstallationConfig.create!(name: 'UMI_SHUMABIT_REPLY',
                               value: { 'inbox_ids' => [inbox.id], 'eligible_after_ms' => cutoff * 1000, 'wait_seconds' => 40 })
  end

  # Builds the note the way the bridge writes it, so the loader is tested against the real marker shape.
  def bridge_note(covered:, outcome: 'reply', seen: covered, at: cutoff + 100, extra: {})
    marker = { 'source_message_id' => covered.last, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => outcome,
               'row_key' => "#{account.id}:#{covered.last}", 'covered_message_ids' => covered.sort, 'eligible_after' => cutoff,
               'seen_digest' => evidence_class.seen_digest(seen) }
    marker.update('reply' => 'Yes, size M is in stock.', 'staff' => 'Check the shelf first.') if %w[reply still_applies].include?(outcome)
    create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'Shumabit draft',
                     created_at: Time.zone.at(at), content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker.merge(extra) })
  end

  def status_reply(classes, ambiguous: false)
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { draft_status: 'none', terminal_reason: nil, note_id: nil, disposition: nil, validation_code: nil, output_bytes: nil,
              note_status: nil, conversation_busy: classes.value?('active'), conversation_ambiguous: ambiguous,
              message_classes: classes.transform_keys(&:to_s) }.to_json }
  end

  it 'serves the reply of a note made with exactly the current eligible input, never its staff text' do
    bridge_note(covered: [question.id])
    answer = loader.new(conversation: conversation, config: config, mode: :tap).call
    expect(answer.http).to eq(200)
    expect(answer.body).to eq({ message: 'Yes, size M is in stock.' })
    expect(answer.headers).to be_empty
    expect(a_request(:post, status_url)).not_to have_been_made
  end

  it 'denies a redacted or missing contact before reading any note or status' do
    bridge_note(covered: [question.id])
    contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
    answer = loader.new(conversation: conversation.reload, config: config, mode: :tap).call
    expect([answer.http, answer.code, answer.headers]).to eq([422, :contact_unavailable, {}])
    expect(answer.body.to_json).not_to include('size M')
    conversation.update_column(:contact_id, nil) # rubocop:disable Rails/SkipsModelValidations
    expect(loader.new(conversation: conversation.reload, config: config, mode: :tap).call.code).to eq(:contact_unavailable)
  end

  it 'denies a redacted contact before any status call when no draft exists yet' do
    question
    stub_request(:post, status_url).to_return(status_reply({ question.id => 'active' }))
    contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
    answer = loader.new(conversation: conversation, config: config, mode: :tap).call
    expect([answer.code, answer.headers]).to eq([:contact_unavailable, {}])
    expect(a_request(:post, status_url)).not_to have_been_made
  end

  it 'answers before_activation for a tail at or before the cutoff second, without a status call' do
    create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 0.5))
    expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:before_activation)
    expect(a_request(:post, status_url)).not_to have_been_made
  end

  it 'answers every non-reply outcome with its own fixed text' do
    { 'no_reply' => 'Shumabit found nothing new to answer; read the latest Shumabit note.',
      'non_actionable' => 'Shumabit found nothing new to answer; read the latest Shumabit note.',
      'needs_staff' => 'Shumabit needs staff for this; read the latest Shumabit note.',
      'unsupported' => 'Shumabit needs staff for this; read the latest Shumabit note.',
      'invalid' => "Shumabit's draft failed validation; read the latest Shumabit note.",
      'failed' => 'Shumabit could not complete this draft; write the reply or ask @shumabit.',
      'interrupted' => 'Shumabit could not complete this draft; write the reply or ask @shumabit.',
      'public_reply_sent' => 'A public reply was sent meanwhile; read the thread.',
      'resolved' => 'The conversation was resolved; Shumabit made no draft.',
      'not_received_newer' => 'A newer message did not reach Shumabit; write the reply or ask @shumabit.',
      'member_deleted' => 'A message was deleted meanwhile; write the reply or ask @shumabit.' }.each do |outcome, text|
      Message.where(private: true).destroy_all
      bridge_note(covered: [question.id], outcome: outcome)
      answer = loader.new(conversation: conversation, config: config, mode: :tap).call
      expect([answer.http, answer.body]).to eq([422, { error: text }]), outcome
    end
  end

  it 'serves the newest of several notes made with the same eligible input' do
    bridge_note(covered: [question.id], at: cutoff + 100)
    bridge_note(covered: [question.id], outcome: 'needs_staff', at: cutoff + 101)
    expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:needs_staff)
  end

  it 'loads a mixed-input reply with no staff text and unreadable members, returning only the reply' do
    bridge_note(covered: [question.id], extra: { 'staff' => nil, 'inspect_message_ids' => [question.id] })
    expect(loader.new(conversation: conversation, config: config, mode: :tap).call.body).to eq({ message: 'Yes, size M is in stock.' })
  end

  it 'denies when redaction commits while the status call runs, even if a note landed meanwhile' do
    second = create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 20))
    bridge_note(covered: [question.id])
    stub_request(:post, status_url).to_return do
      bridge_note(covered: [second.id], seen: [question.id, second.id], at: cutoff + 200)
      contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
      status_reply({ second.id => 'active' })
    end
    answer = loader.new(conversation: conversation, config: config, mode: :tap).call
    expect(answer.code).to eq(:contact_unavailable)
  end

  it 'serves a re-issued draft only while its origin note is live' do
    note = bridge_note(covered: [question.id])
    thanks = create(:message, conversation: conversation, message_type: :incoming, sender: contact, content: '🙏',
                              created_at: Time.zone.at(cutoff + 150))
    bridge_note(covered: [thanks.id], outcome: 'still_applies', seen: [question.id, thanks.id], at: cutoff + 160,
                extra: { 'origin_note_id' => note.id, 'origin_covered_message_ids' => [question.id], 'origin_created_at' => cutoff + 100 })
    expect(loader.new(conversation: conversation, config: config, mode: :tap).call.body).to eq({ message: 'Yes, size M is in stock.' })
    note.update!(content_attributes: { 'deleted' => true })
    expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:deleted)
  end

  it 'enforces the channel limit and the text check defensively, with fixed answers' do
    stub_request(:post, /graph\.facebook\.com/)
    facebook = create(:inbox, account: account, channel: create(:channel_facebook_page, account: account))
    InstallationConfig.find_by(name: 'UMI_SHUMABIT_REPLY').update!(value: { 'inbox_ids' => [facebook.id], 'eligible_after_ms' => cutoff * 1000 })
    conversation.update!(inbox: facebook)
    bridge_note(covered: [question.id], extra: { 'reply' => 'x' * 1001 })
    expect(loader.new(conversation: conversation, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call.code)
      .to eq(:too_long)
    Message.where(private: true).destroy_all
    bridge_note(covered: [question.id], extra: { 'reply' => 'For Mai: verify stock first' })
    answer = loader.new(conversation: conversation, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call
    expect(answer.code).to eq(:invalid)
    expect(answer.body.to_json).not_to include('verify stock')
  end

  it 'answers a current non-reply outcome with its fixed reason, never the note text' do
    bridge_note(covered: [question.id], outcome: 'needs_staff')
    answer = loader.new(conversation: conversation, config: config, mode: :tap).call
    expect([answer.http, answer.code]).to eq([422, :needs_staff])
    expect(answer.body[:error]).to eq('Shumabit needs staff for this; read the latest Shumabit note.')
  end

  describe 'without a current outcome' do
    it 'waits only while the bridge has an active membership, with Rails-built wait headers' do
      question
      stub_request(:post, status_url).to_return(status_reply({ question.id => 'active' }))
      freeze_time do
        answer = loader.new(conversation: conversation, config: config, mode: :tap).call
        expect([answer.http, answer.code]).to eq([422, :pending])
        expect(answer.headers).to eq(
          'X-Umi-Shumabit-Wait' => "a=#{account.id};c=#{conversation.display_id};m=#{question.id};d=#{Time.current.to_i + 40}",
          'X-Umi-Shumabit-Recheck' => "/api/v1/accounts/#{account.id}/umi/shumabit_reply/#{conversation.display_id}/completion"
        )
      end
      expect(a_request(:post, status_url).with(body: { event: 'umi_draft_status', account: { id: account.id },
                                                       conversation: { id: conversation.display_id }, tail_message_id: question.id,
                                                       message_ids: [question.id] })).to have_been_made.once
      completion = loader.new(conversation: conversation, config: config, mode: :completion).call
      expect([completion.code, completion.headers]).to eq([:not_finished, {}])
    end

    it 'answers a young tail the bridge has not seen with a plain pending, then not_received after 10 seconds' do
      travel_to(Time.zone.at(cutoff + 15)) do
        question
        stub_request(:post, status_url).to_return(status_reply({ question.id => 'unknown' }))
        answer = loader.new(conversation: conversation, config: config, mode: :tap).call
        expect([answer.code, answer.headers]).to eq([:pending, {}])
      end
      travel_to(Time.zone.at(cutoff + 25)) do
        expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:not_received)
      end
    end

    it 'maps the remaining bridge classes to their fixed answers' do
      question
      { 'reserved' => :ambiguous, 'attempted' => :no_result, 'ended' => :no_result }.each do |klass, code|
        stub_request(:post, status_url).to_return(status_reply({ question.id => klass }))
        expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(code), klass
      end
      stub_request(:post, status_url).to_return(status_reply({ question.id => 'unknown' }, ambiguous: true))
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:ambiguous)
    end

    it 'treats any malformed, foreign or failed status answer as unavailable' do
      question
      good = JSON.parse(status_reply({ question.id => 'active' })[:body])
      [{ status: 400, body: { error: 'invalid_status_request' }.to_json }, { status: 200, body: { draft_status: 'unavailable' }.to_json },
       { status: 302, headers: { 'Location' => 'http://elsewhere.test' } }, { status: 200, body: 'not json' },
       { status: 200, body: good.merge('message_classes' => { '1' => 'active' }).to_json },
       { status: 200, body: good.merge('message_classes' => { question.id.to_s => 'busy' }).to_json },
       { status: 200, body: good.except('conversation_ambiguous').to_json },
       { status: 200, body: good.merge('note_status' => 'sent').to_json }].each do |reply|
        stub_request(:post, status_url).to_return(reply)
        expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:unavailable), reply.inspect
      end
      stub_request(:post, status_url).to_timeout
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:unavailable)
    end

    it 'answers pending without wait headers when the deciding read sees new input the bridge did not classify' do
      question
      stub_request(:post, status_url).to_return do
        create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 30))
        status_reply({ question.id => 'active' })
      end
      answer = loader.new(conversation: conversation, config: config, mode: :tap).call
      expect([answer.code, answer.headers]).to eq([:pending, {}])
    end

    it 'asks about exactly 50 messages' do
      50.times do |index|
        create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + index + 1))
      end
      stub_request(:post, status_url).to_return do |request|
        status_reply(JSON.parse(request.body)['message_ids'].index_with('active'))
      end
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:pending)
    end

    it 'logs a status failure by exception class only, never the bridge address' do
      question
      warnings = []
      allow(Rails.logger).to receive(:warn) { |line| warnings << line }
      stub_request(:post, status_url).to_raise(SocketError.new('Failed to open TCP connection to bridge.test:80'))
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:unavailable)
      expect(warnings).to eq(['[umi-shumabit-reply] status unavailable: SocketError'])
    end

    it 'never asks about more than 50 messages' do
      51.times do |index|
        create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + index + 1))
      end
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:unavailable)
      expect(a_request(:post, status_url)).not_to have_been_made
    end

    it 'explains a conversation whose eligible input changed by deletion since the last note' do
      second = create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 20))
      bridge_note(covered: [question.id, second.id])
      second.update!(content_attributes: { 'deleted' => true })
      stub_request(:post, status_url).to_return(status_reply({}))
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:deleted)
      Message.where(private: true).destroy_all
      bridge_note(covered: [question.id], seen: [question.id, second.id])
      expect(loader.new(conversation: conversation, config: config, mode: :tap).call.code).to eq(:changed)
    end
  end

  it 'answers unavailable when the bridge address or bridge user is not configured' do
    question
    with_modified_env(UMI_SHUMABIT_BRIDGE_URL: nil) do
      expect(loader.new(conversation: conversation, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call.code).to eq(:unavailable)
    end
    with_modified_env(UMI_COMMERCE_BRIDGE_USER_ID: nil) do
      expect(loader.new(conversation: conversation, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call.code).to eq(:unavailable)
    end
  end

  # English assistance lives only in the private note: the marker may carry the customer's and the reply's English
  # translations next to the staff text, but the composer gets the customer-language reply and nothing else, whether
  # the translations are valid, missing or malformed. The case is the bridge's synthetic English-assistance loader
  # fixture; database ids and the cutoff are mapped as in the membership cases below.
  describe 'shared English assistance case' do
    let(:fixture) do
      { cutoff: 50, source: { content: 'มีไซซ์ M ไหมคะ', at: 70 }, note_at: 200, reply: 'มีค่ะ',
        customer_english: [{ 'language' => 'other', 'english' => 'Is size M available?' }],
        reply_english: { 'language' => 'other', 'english' => 'It is available.' },
        must_not_expose: ['customer_english', 'reply_english', 'Is size M available?', 'It is available.'] }
    end

    it 'loads only marker.reply for valid, missing and malformed translations, never a translation or the staff text' do
      malformed = { 'language' => 'french', 'english' => 'Is size M available?', 'extra' => 1 }
      variants = {
        valid: lambda { |id|
          { 'customer_english' => fixture[:customer_english].map do |entry|
            entry.merge('id' => id)
          end, 'reply_english' => fixture[:reply_english] }
        },
        missing: ->(_id) { {} },
        malformed: ->(id) { { 'customer_english' => [malformed.merge('id' => id)] * 2, 'reply_english' => ['It is available.'] } }
      }
      staff_texts = [nil, 'Stock checked in Shopify.']
      InstallationConfig.find_by(name: 'UMI_SHUMABIT_REPLY').update!(value: { 'inbox_ids' => [inbox.id],
                                                                              'eligible_after_ms' => fixture[:cutoff] * 1000 })

      variants.to_a.product(staff_texts).each do |(name, english), staff|
        Message.where(conversation: conversation).destroy_all
        source = create(:message, conversation: conversation, message_type: :incoming, sender: contact,
                                  content: fixture[:source][:content], created_at: Time.zone.at(fixture[:source][:at]))
        marker = { 'source_message_id' => source.id, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
                   'row_key' => "#{account.id}:#{source.id}", 'covered_message_ids' => [source.id], 'eligible_after' => fixture[:cutoff],
                   'seen_digest' => evidence_class.seen_digest([source.id]), 'reply' => fixture[:reply], 'staff' => staff }
        create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'Shumabit draft',
                         created_at: Time.zone.at(fixture[:note_at]),
                         content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker.merge(english.call(source.id)) })

        answer = loader.new(conversation: conversation.reload, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call

        expect([answer.http, answer.body]).to eq([200, { message: fixture[:reply] }]), "#{name} staff=#{staff.inspect}"
        (fixture[:must_not_expose] + [staff].compact).each do |text|
          expect(answer.body.to_json).not_to include(text), "#{name}: #{text}"
        end
      end
    end

    it 'gives no text for an outcome without a reply, even when it carries the customer translation' do
      bridge_note(covered: [question.id], outcome: 'needs_staff',
                  extra: { 'staff' => 'Price unknown.',
                           'customer_english' => [{ 'id' => question.id, 'language' => 'other', 'english' => 'How much is it?' }] })

      answer = loader.new(conversation: conversation, config: config, mode: :tap).call

      expect(answer.code).to eq(:needs_staff)
      expect(answer.body.to_json).not_to include('How much is it?')
      expect(answer.body.to_json).not_to include('Price unknown.')
    end
  end

  # A staff request can make Shumabit post a revision R of the current draft T. R names T's customer messages (for a
  # re-issued T, also the messages of T's origin), carries T's seen digest and revision_of, and its row key is the staff
  # note's. The loader needs no rule for it: the newest current note wins. The cases are the bridge's synthetic
  # staff-direction loader fixture; database ids and the cutoff are mapped as in the membership cases below.
  describe 'shared staff direction cases' do
    let(:texts) do
      { draft: 'มีค่ะ', revised: 'มีค่ะ ขอเช็กสต็อกก่อนนะคะ', staff: 'Verify current stock.',
        revised_staff: 'Verify current stock; shorter wording follows the staff request.',
        customer_english: 'Is size M available?', reply_english: 'It is available.' }
    end

    before do
      InstallationConfig.find_by(name: 'UMI_SHUMABIT_REPLY').update!(value: { 'inbox_ids' => [inbox.id], 'eligible_after_ms' => 50_000 })
    end

    def customer(at)
      create(:message, conversation: conversation, message_type: :incoming, sender: contact, content: 'มีไซซ์ M ไหมคะ',
                       created_at: Time.zone.at(at))
    end

    # A revision (extra carries revision_of) has the revised reply and staff text; every other note has the draft's.
    def draft(at:, covered:, row: covered.max, extra: {})
      revised = extra.key?('revision_of')
      marker = { 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'row_key' => "#{account.id}:#{row}",
                 'source_message_id' => covered.max, 'covered_message_ids' => covered.sort, 'eligible_after' => 50,
                 'seen_digest' => evidence_class.seen_digest(covered), 'outcome' => 'reply',
                 'reply' => texts[revised ? :revised : :draft], 'staff' => texts[revised ? :revised_staff : :staff],
                 'customer_english' => [{ 'id' => covered.min, 'language' => 'other', 'english' => texts[:customer_english] }],
                 'reply_english' => { 'language' => 'other', 'english' => texts[:reply_english] } }.merge(extra)
      create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'Shumabit draft',
                       created_at: Time.zone.at(at), content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker })
    end

    def staff_request(at, signed_in:)
      create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge,
                       content: '@shumabit make it shorter', created_at: Time.zone.at(at),
                       content_attributes: signed_in ? { 'umi_signed_in_sender_id' => bridge.id } : {})
    end

    def answer
      loader.new(conversation: conversation.reload, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call
    end

    def expect_message(text)
      result = answer
      expect([result.http, result.body]).to eq([200, { message: text }])
      [texts[:staff], texts[:revised_staff], texts[:customer_english], texts[:reply_english], 'customer_english', 'reply_english',
       '"staff"'].each { |hidden| expect(result.body.to_json).not_to include(hidden) }
    end

    it 'serves the newest verified revision, and the target again only once the revision is deleted' do
      question = customer(70)
      request = staff_request(130, signed_in: true)
      target = draft(at: 200, covered: [question.id])
      expect_message(texts[:draft])

      revision = draft(at: 201, covered: [question.id], row: request.id, extra: { 'revision_of' => target.id })
      expect_message(texts[:revised])

      revision.update!(content_attributes: { 'deleted' => true })
      expect_message(texts[:draft])
    end

    it 'keeps serving the revision when its target is deleted' do
      question = customer(70)
      request = staff_request(130, signed_in: true)
      target = draft(at: 200, covered: [question.id])
      draft(at: 201, covered: [question.id], row: request.id, extra: { 'revision_of' => target.id })

      target.update!(content_attributes: { 'deleted' => true })

      expect_message(texts[:revised])
    end

    it 'serves the target while a revision is in flight or after a failed one, whatever the staff note carries' do
      question = customer(70)
      draft(at: 200, covered: [question.id])

      [true, false].each do |signed_in|
        request = staff_request(130, signed_in: signed_in)
        expect_message(texts[:draft])
        create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge,
                         content: 'Shumabit: could not finish this request (error); the current draft is unchanged.',
                         created_at: Time.zone.at(202), content_attributes: { 'shumabit_bridge' => true })
        expect_message(texts[:draft])
        request.destroy!
      end
    end

    it "serves a revision of a re-issued draft, which also names the origin's question" do
      question = customer(70)
      thanks = customer(80)
      request = staff_request(130, signed_in: true)
      origin = draft(at: 200, covered: [question.id])
      reissue = draft(at: 201, covered: [thanks.id],
                      extra: { 'outcome' => 'still_applies', 'origin_note_id' => origin.id, 'origin_covered_message_ids' => [question.id],
                               'origin_created_at' => 200, 'seen_digest' => evidence_class.seen_digest([question.id, thanks.id]) })
      expect_message(texts[:draft])

      draft(at: 202, covered: [question.id, thanks.id], row: request.id, extra: { 'revision_of' => reissue.id })

      expect_message(texts[:revised])
    end
  end

  # The seven synthetic cases shared with the bridge (shumabit-claude tools/chatwoot-bridge/test-support/assist-cases.cjs).
  # Fixture ids and times are kept apart: database ids follow the fixture id order, timestamps are the fixture times.
  describe 'shared membership cases' do
    let(:cases) do
      [{ name: 'a lower-id later public answer closes the higher-id question', cutoff: 50,
         messages: [[:in, 70, 70], [:out, 60, 80]], covered: [], loader: :none },
       { name: 'a higher-id pre-cutoff message cannot exclude eligible lower-id input', cutoff: 100,
         messages: [[:in, 100, 90], [:in, 90, 110]], covered: [], active: [90], loader: :pending },
       { name: 'previously unseen eligible lower-id input is not covered by a maximum', cutoff: 50,
         messages: [[:in, 70, 70], [:in, 65, 80]], covered: [70], active: [65], loader: :pending },
       { name: 'a new higher-id older-time question invalidates a result without moving chronological tail', cutoff: 50,
         messages: [[:in, 70, 100], [:in, 80, 90]], covered: [70], active: [80], loader: :pending },
       { name: 'a late webhook for explicitly covered snapshot input never starts another turn', cutoff: 50,
         messages: [[:in, 70, 70], [:in, 71, 71]], covered: [70, 71], loader: :loaded },
       { name: 'an ambiguous attempt reserves its members while later input is held', cutoff: 50,
         messages: [[:in, 70, 70], [:in, 71, 71]], covered: [], ambiguous: true, loader: :ambiguous },
       { name: 'a deleted outcome cannot authorize replay of its posted attempt', cutoff: 50,
         messages: [[:in, 70, 70]], covered: [], attempted: [70], deleted_outcome: true, loader: :no_result }]
    end

    it 'gives the loader answer the bridge cases expect' do
      cases.each do |sample|
        Message.where(conversation: conversation).destroy_all
        InstallationConfig.find_by(name: 'UMI_SHUMABIT_REPLY').update!(value: { 'inbox_ids' => [inbox.id],
                                                                                'eligible_after_ms' => sample[:cutoff] * 1000 })
        ids = sample[:messages].sort_by { |(_, id, _)| id }.to_h do |(kind, id, time)|
          message = create(:message, conversation: conversation, message_type: kind == :in ? :incoming : :outgoing,
                                     sender: kind == :in ? contact : bridge, created_at: Time.zone.at(time))
          [id, message.id]
        end
        if sample[:deleted_outcome]
          attempted = sample[:attempted].map(&ids)
          marker = { 'source_message_id' => attempted.max, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
                     'row_key' => "#{account.id}:#{attempted.max}", 'covered_message_ids' => attempted, 'eligible_after' => sample[:cutoff],
                     'seen_digest' => evidence_class.seen_digest(attempted), 'reply' => 'Deleted answer.', 'staff' => nil }
          create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'deleted',
                           created_at: Time.zone.at(120),
                           content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker, 'deleted' => true })
        end
        if sample[:covered].any?
          covered = sample[:covered].map(&ids)
          marker = { 'source_message_id' => covered.max, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
                     'row_key' => "#{account.id}:500", 'covered_message_ids' => covered.sort, 'eligible_after' => sample[:cutoff],
                     'seen_digest' => evidence_class.seen_digest(covered), 'reply' => 'Old verified answer.', 'staff' => nil }
          create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'note',
                           created_at: Time.zone.at(120), content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker })
        end
        eligible = sample[:messages].select { |(kind, _, time)| kind == :in && time > sample[:cutoff] }.map { |(_, id, _)| ids[id] }
        classes = (eligible - sample[:covered].map(&ids)).index_with do |id|
          if sample[:ambiguous]
            'reserved'
          elsif sample[:active]&.map(&ids)&.include?(id)
            'active'
          elsif sample[:attempted]&.map(&ids)&.include?(id)
            'attempted'
          else
            'unknown'
          end
        end
        stub_request(:post, status_url).to_return(status_reply(classes, ambiguous: sample[:ambiguous] || false))
        answer = loader.new(conversation: conversation.reload, config: Umi::ShumabitReply::Configuration.current, mode: :tap).call
        expect(answer.http == 200 ? :loaded : answer.code).to eq(sample[:loader]), sample[:name]
        expect(answer.body).to eq({ message: 'Old verified answer.' }) if sample[:loader] == :loaded
      end
    end
  end
end
