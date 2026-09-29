# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Funnel::OperationalReport' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Bangkok', working_hours_enabled: false) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, created_at: start) }
  let(:agent) { create(:user, account: account) }
  let(:start) { Time.iso8601('2026-09-25T09:00:00Z') }
  let(:params) { { account_id: account.id, since: start, until_time: start + 1.day, as_of: start + 2.days } }
  let(:report) { Umi::Funnel::OperationalReport.perform(**params) }
  let(:row) { report[:rows].sole }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: '', UMI_FUNNEL_STARTED_AT: '2026-09-01T00:00:00Z' do
      example.run
    end
  end

  def message(at, type: :incoming, **attributes)
    create(:message, account: account, inbox: inbox, conversation: conversation, created_at: at,
                     sender: type == :outgoing ? agent : conversation.contact, message_type: type, **attributes)
  end

  it 'keeps the burst timer through private, automated and bot replies across the week boundary' do
    message(start, content: 'Secret customer content')
    message(start + 30.seconds)
    message(start + 60.seconds, type: :outgoing, private: true)
    message(start + 90.seconds, type: :outgoing, content_attributes: { automation_rule_id: 1 })
    message(start + 120.seconds, type: :outgoing, sender: create(:agent_bot))
    message(start + 130.seconds, type: :outgoing, additional_attributes: { campaign_id: 1 })
    message(start + 1.day + 5.minutes, type: :outgoing)
    before_count = ReportingEvent.count

    expect(row[:first_response]).to include(eligible: 1, responded: 1, response_rate: 1.0)
    expect(row[:first_response][:completed_calendar_seconds]).to eq(n: 1, mean: 86_700.0, median: 86_700.0, p90: 86_700.0)
    expect(row[:first_response][:sla]).to include(status: 'unavailable', eligible: nil, pending: nil)
    expect(ReportingEvent.count).to eq(before_count)
    expect(JSON.generate(report)).not_to include('Secret customer content', 'contact_id', 'conversation_id', 'message_id')
  end

  it 'keeps unanswered not_sales conversations in the denominator and reports age' do
    conversation.project_umi_sales_status!('not_sales')
    message(start)
    message(start + 1.day, type: :outgoing, private: true)

    expect(row[:first_response]).to include(eligible: 1, responded: 0, response_rate: 0.0)
    expect(row[:first_response][:completed_calendar_seconds]).to include(n: 0, mean: nil)
    expect(row[:first_response][:unresolved]).to include(count: 1, calendar_age_seconds: { n: 1, mean: 172_800.0,
                                                                                           median: 172_800.0, p90: 172_800.0 })
  end

  it 'never reacquires an older conversation and starts subsequent episodes only after a human reply' do
    message(start - 1.day)
    message(start - 1.hour, type: :outgoing)
    message(start)
    conversation.update!(status: :resolved)
    conversation.update!(status: :open)
    message(start + 1.minute)
    message(start + 3.minutes, type: :outgoing)
    message(start + 4.minutes)

    expect(row[:first_response][:eligible]).to eq(0)
    expect(row[:subsequent_response]).to include(eligible: 2, responded: 1, response_rate: 0.5)
    expect(row[:subsequent_response][:completed_calendar_seconds][:mean]).to eq(180.0)
    expect(row[:subsequent_response][:unresolved][:count]).to eq(1)
  end

  it 'ignores reopening as a start or reset for unanswered episodes' do
    message(start)
    conversation.update!(status: :resolved)
    conversation.update!(status: :open)
    message(start + 2.minutes)
    message(start + 6.minutes, type: :outgoing)

    expect(row[:first_response][:completed_calendar_seconds][:mean]).to eq(360.0)
    expect(row[:subsequent_response][:eligible]).to eq(0)
  end

  it 'uses half-open episode boundaries and does not include replies after as_of' do
    message(start)
    message(start + 1.minute, type: :outgoing)
    message(start + 1.day)
    message(start + 3.days, type: :outgoing)

    expect(row[:first_response][:eligible]).to eq(1)
    expect(row[:subsequent_response][:eligible]).to eq(0)
    expect(Umi::Funnel::OperationalReport.perform(**params, since: start + 1.day, until_time: start + 2.days)[:rows]
                                         .sole[:subsequent_response]).to include(eligible: 1, responded: 0)
  end

  it 'counts only explicit spam and incoming auto-reply notifications as exclusions' do
    conversation.update!(label_list: ['spam'])
    message(start)
    expect(row[:coverage][:excluded_spam_conversations]).to eq(1)
    expect(row[:first_response][:eligible]).to eq(0)
  end

  it 'reports recovered and missing source timestamps as chronology exceptions rather than new acquisitions' do
    message(start - 1.day, content_attributes: { umi_recovered: true, external_created_at: 'unknown' })
    message(start)
    message(start + 5.minutes, type: :outgoing)

    expect(row[:coverage]).to include(recovered_chronology_conversations: 1, unknown_source_timestamp_conversations: 1)
    expect(row[:first_response][:eligible]).to eq(0)
  end

  it 'marks a partial collection period instead of fabricating a full zero week' do
    message(start)
    with_modified_env UMI_FUNNEL_STARTED_AT: (start + 1.hour).iso8601 do
      expect(report[:coverage]).to include(period_complete: false, effective_from: (start + 1.hour).iso8601)
      expect(row[:first_response][:eligible]).to eq(0)
    end
  end

  it 'rejects invalid windows and filters inboxes within the account' do
    expect { Umi::Funnel::OperationalReport.perform(**params, as_of: start) }.to raise_error(ArgumentError)
    other = create(:inbox)
    expect { Umi::Funnel::OperationalReport.perform(**params, inbox_id: other.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'uses saved Bangkok working hours across the night and weekend without global timezone mutation' do
    inbox.update!(working_hours_enabled: true)
    friday = Time.iso8601('2026-09-25T09:58:00Z')
    monday = Time.iso8601('2026-09-28T02:03:00Z')
    message(friday)
    message(monday, type: :outgoing)
    original_zone = Time.zone
    original_config_zone = WorkingHours::Config.time_zone
    result = Umi::Funnel::OperationalReport.perform(**params, as_of: monday)[:rows].sole[:first_response]

    expect(result[:completed_business_seconds][:mean]).to eq(300.0)
    expect(result[:sla]).to include(status: 'available', eligible: 1, met: 1, missed: 0, pending: 0)
    expect(Time.zone).to eq(original_zone)
    expect(WorkingHours::Config.time_zone).to eq(original_config_zone)
  end

  it 'keeps fractional seconds when distinguishing missed and pending SLA' do
    inbox.update!(working_hours_enabled: true)
    message(start)
    message(start + 300.001.seconds, type: :outgoing)
    result = row[:first_response]
    expect(result[:sla]).to include(eligible: 1, met: 0, missed: 1, pending: 0)
  end

  it 'keeps unanswered episodes pending until five working minutes have elapsed' do
    inbox.update!(working_hours_enabled: true)
    message(start)
    result = Umi::Funnel::OperationalReport.perform(**params, until_time: start + 1.second, as_of: start + 299.999.seconds)
    expect(result[:rows].sole[:first_response][:sla]).to include(eligible: 0, missed: 0, pending: 1)
    result = Umi::Funnel::OperationalReport.perform(**params, until_time: start + 1.second, as_of: start + 300.seconds)
    expect(result[:rows].sole[:first_response][:sla]).to include(eligible: 1, missed: 1, pending: 0)
  end

  it 'counts applied classification within 24 hours and leaves immature unclassified cases pending' do
    message(start)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', provenance: 'operator', occurrence_key: 'classification:example',
                                   occurred_at: start + 23.hours, observed_at: start + 23.hours, payload: { status: 'engaged' })
    expect(row[:classification_within_24h]).to include(eligible: 1, met: 1, missed: 0, pending: 0)
  end

  it 'excludes known email auto-replies without excluding later customer messages' do
    message(start, content_type: :incoming_email, content_attributes: { email: { auto_reply: true } })
    message(start + 1.minute)
    message(start + 2.minutes, type: :outgoing)
    expect(row[:coverage][:excluded_service_notification_messages]).to eq(1)
    expect(row[:first_response][:completed_calendar_seconds][:mean]).to eq(60.0)
  end

  it 'does not count notifications outside the reporting period as this weeks exclusions' do
    message(start - 1.day, content_type: :incoming_email, content_attributes: { email: { auto_reply: true } })
    message(start)
    message(start + 1.minute, type: :outgoing)
    message(start + 1.day, content_type: :incoming_email, content_attributes: { email: { auto_reply: true } })

    expect(row[:coverage][:excluded_service_notification_messages]).to eq(0)
    expect(row[:first_response][:completed_calendar_seconds][:mean]).to eq(60.0)
  end

  it 'ignores failed replies and counts a persisted public native-app echo as human response' do
    message(start)
    message(start + 1.minute, type: :outgoing, status: :failed)
    message(start + 3.minutes, type: :outgoing, sender: conversation.contact, content_attributes: { external_echo: true })
    expect(row[:first_response][:completed_calendar_seconds][:mean]).to eq(180.0)
  end

  it 'reports nearest-rank p90 and midpoint median over completed intervals only' do
    message(start)
    message(start + 1.minute, type: :outgoing)
    message(start + 2.minutes)
    message(start + 4.minutes, type: :outgoing)
    message(start + 5.minutes)
    message(start + 9.minutes, type: :outgoing)
    expect(row[:subsequent_response][:completed_calendar_seconds]).to eq(n: 2, mean: 180.0, median: 180.0, p90: 240.0)
  end

  it 'reports pending then missed classification without counting shadow evaluations as applied classification' do
    message(start)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_evaluated', provenance: 'classifier', occurrence_key: 'shadow:example',
                                   occurred_at: start + 1.hour, observed_at: start + 1.hour,
                                   payload: { outcome: 'shadow', decision: { status: 'engaged' } })
    result = Umi::Funnel::OperationalReport.perform(**params, until_time: start + 1.hour, as_of: start + 23.hours)
    expect(result[:rows].sole[:classification_within_24h]).to include(eligible: 0, met: 0, missed: 0, pending: 1)
    expect(row[:classification_within_24h]).to include(eligible: 1, met: 0, missed: 1, pending: 0)
  end

  it 'counts an uncertain automatic assessment as evaluated while keeping its clarification age visible' do
    message(start)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_evaluated', provenance: 'classifier', occurrence_key: 'uncertain:example',
                                   occurred_at: start + 1.hour, observed_at: start + 1.hour,
                                   payload: { mode: 'auto', outcome: 'uncertain', decision: { status: 'uncertain' } })

    expect(row[:classification_within_24h]).to include(eligible: 1, met: 1, missed: 0, pending: 0)
    expect(row[:classification_status][:needs_clarification]).to include(count: 1, calendar_age_seconds: {
                                                                           n: 1, mean: 172_800.0, median: 172_800.0, p90: 172_800.0
                                                                         })
    expect(row[:classification_status][:unevaluated][:count]).to eq(0)
  end

  it 'keeps missing or failed assessments in the unevaluated queue' do
    message(start)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_evaluated', provenance: 'classifier', occurrence_key: 'failed:example',
                                   occurred_at: start + 1.hour, observed_at: start + 1.hour,
                                   payload: { mode: 'auto', outcome: 'failed', decision: {} })

    expect(row[:classification_status][:unevaluated]).to include(count: 1, calendar_age_seconds: {
                                                                   n: 1, mean: 172_800.0, median: 172_800.0, p90: 172_800.0
                                                                 })
  end

  it 'keeps the first assessment deadline when the operator later resolves uncertainty' do
    message(start)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', provenance: 'operator', occurrence_key: 'uncertain:operator',
                                   occurred_at: start + 1.hour, observed_at: start + 1.hour, payload: { status: 'uncertain' })
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', provenance: 'operator', occurrence_key: 'engaged:operator',
                                   occurred_at: start + 25.hours, observed_at: start + 25.hours, payload: { status: 'engaged' })

    expect(row[:classification_within_24h]).to include(met: 1, missed: 0)
    expect(row[:classification_status]).to include(evaluated: 1)
    expect(row[:classification_status][:needs_clarification][:count]).to eq(0)
  end

  it 'separates Messenger and Instagram within the same inbox and filters other accounts' do
    channel = build(:channel_facebook_page, account: account)
    allow(channel).to receive(:subscribe)
    channel.save!
    inbox.update!(channel: channel)
    message(start)
    instagram = create(:conversation, account: account, inbox: inbox, created_at: start,
                                      additional_attributes: { type: 'instagram_direct_message' })
    create(:message, account: account, inbox: inbox, conversation: instagram, created_at: start)
    create(:message, created_at: start)
    expect(report[:rows].map { |item| [item[:messaging_channel], item[:first_response][:eligible]] })
      .to eq([['instagram', 1], ['messenger', 1]])
  end

  it 'keeps exclusion coverage scoped to conversations with incoming messages in the collection period' do
    conversation.update!(label_list: ['spam'])
    message(start - 1.day)
    expect(row[:coverage][:excluded_spam_conversations]).to eq(0)
  end
end
