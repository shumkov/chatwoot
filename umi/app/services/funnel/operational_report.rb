# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::OperationalReport
  CLASSIFIED_STATUSES = %w[engaged qualified inactive not_sales order_placed purchased uncertain].freeze
  EVALUATED_OUTCOMES = %w[applied uncertain].freeze

  def self.perform(**arguments)
    new(**arguments).perform
  end

  def initialize(account_id:, since:, until_time:, as_of:, inbox_id: nil)
    @account = Account.find(account_id)
    @from, @until_time, @as_of = [since, until_time, as_of].map { |time| time.is_a?(String) ? Time.iso8601(time).utc : time.utc }
    raise ArgumentError, 'Invalid operational report window' unless @from < @until_time && @until_time <= @as_of

    @boundary = Umi::Funnel::Configuration.started_at
    @effective_from = [@from, @boundary].max
    @inboxes = inbox_id ? [@account.inboxes.find(inbox_id)] : @account.inboxes.order(:id).to_a
    @rows = {}
  end

  def perform
    @inboxes.each do |inbox|
      row_for(inbox, 'other') unless inbox.channel_type.in?(%w[Channel::FacebookPage Channel::Instagram])
      candidates = inbox.messages.incoming.where(private: false, created_at: @effective_from...@until_time).select(:conversation_id)
      @account.conversations.where(inbox_id: inbox.id, id: candidates).includes(:contact).find_each do |conversation|
        collect(conversation, row_for(inbox, messaging_channel(conversation, inbox)))
      end
    end
    { schema_version: 1, account_id: @account.id, as_of: @as_of.iso8601(6),
      period: { from: @from.iso8601, until: @until_time.iso8601, boundary: 'half_open' },
      observation_boundary: @boundary.iso8601,
      knowledge_basis: 'current_persisted_messages_classification_events_and_inbox_schedule', historical_restatement_possible: true,
      coverage: { inbox_ids: @inboxes.map(&:id), scope: 'selected_account_inboxes', period_complete: @from >= @boundary,
                  effective_from: @effective_from.iso8601 },
      targets: { first_response_business_seconds: 300, response_rate_greater_than: 0.95 }, percentile_method: 'nearest_rank',
      rows: @rows.sort_by { |key, _| key }.map { |_, row| finish(row) },
      limitations: %w[current_schedule_and_spam_labels_not_historical unknown_service_notifications_not_inferred
                      recovered_chronology_excluded ad_comments_not_verified] }
  end

  private

  def messaging_channel(conversation, inbox)
    return 'instagram' if inbox.channel_type == 'Channel::Instagram' || conversation.additional_attributes['type'] == 'instagram_direct_message'

    inbox.channel_type == 'Channel::FacebookPage' ? 'messenger' : 'other'
  end

  def row_for(inbox, channel)
    @rows[[inbox.id, channel]] ||= {
      inbox_id: inbox.id, channel_type: inbox.channel_type, messaging_channel: channel,
      business_hours: { status: inbox.working_hours_enabled? ? 'available' : 'unavailable', timezone: inbox.timezone,
                        basis: 'current_inbox_schedule', schedule: inbox.working_hours_enabled? ? inbox.weekly_schedule : nil },
      coverage: { scope: 'conversations_with_incoming_in_collection_period', inspected_conversations: 0,
                  excluded_spam_conversations: 0, excluded_service_notification_messages: 0,
                  redacted_conversations: 0, recovered_chronology_conversations: 0, unknown_source_timestamp_conversations: 0 },
      first_response: [], subsequent_response: [], inbox: inbox
    }
  end

  def collect(conversation, row)
    messages = conversation.messages.where(private: false, message_type: %i[incoming outgoing]).where(created_at: ..@as_of)
                           .reorder(:created_at, :id).includes(:sender).to_a
    return unless messages.any? { |message| message.incoming? && message.created_at < @until_time }

    coverage = row[:coverage]
    coverage[:inspected_conversations] += 1
    if conversation.contact.additional_attributes['umi_profile_redacted']
      coverage[:redacted_conversations] += 1
      return
    end
    if conversation.label_list.include?('spam')
      coverage[:excluded_spam_conversations] += 1
      return
    end
    return if uncertain_chronology?(messages, coverage)

    episodes = []
    waiting = nil
    messages.each do |message|
      if message.incoming?
        if message.auto_reply_email?
          coverage[:excluded_service_notification_messages] += 1 if message.created_at >= @effective_from && message.created_at < @until_time
          next
        end
        waiting ||= { start: message.created_at, finish: nil }
      elsif waiting && !message.failed? && !message.send(:bot_response?) && message.send(:human_response?)
        episodes << waiting.merge(finish: message.created_at)
        waiting = nil
      end
    end
    episodes << waiting if waiting
    episodes.each_with_index do |episode, index|
      next unless episode[:start] >= @effective_from && episode[:start] < @until_time

      # A first message observed after collection began cannot establish acquisition for an older imported thread.
      next if index.zero? && conversation.created_at < @boundary

      episode.merge!(classification(conversation, episode[:start])) if index.zero?
      row[index.zero? ? :first_response : :subsequent_response] << episode
    end
  end

  def uncertain_chronology?(messages, coverage)
    recovered = messages.select { |message| message.content_attributes['umi_recovered'] == true }
    return false if recovered.empty?

    coverage[:recovered_chronology_conversations] += 1
    if recovered.any? { |message| Umi::Funnel::EventRecorder.source_time(message.content_attributes['external_created_at']).nil? }
      coverage[:unknown_source_timestamp_conversations] += 1
    end
    true
  end

  def classification(conversation, start)
    events = Umi::ConversationEvent.where(account_id: @account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                          redacted_at: nil, event_type: %w[classification_changed classification_evaluated])
                                   .where(occurred_at: start..@as_of, observed_at: ..@as_of).order(:occurred_at, :id)
    result = { classification_at: nil, classification_status: 'unevaluated' }
    events.each do |event|
      payload = event.payload
      status = if event.event_type == 'classification_changed'
                 payload['status']
               elsif payload['mode'] == 'auto' && EVALUATED_OUTCOMES.include?(payload['outcome'])
                 payload.dig('decision', 'status')
               end
      next unless CLASSIFIED_STATUSES.include?(status) || status == 'unevaluated'

      result[:classification_at] ||= event.occurred_at if CLASSIFIED_STATUSES.include?(status)
      result[:classification_status] = status
    end
    result
  end

  def finish(row)
    inbox = row.delete(:inbox)
    first = row[:first_response]
    row[:classification_within_24h] = deadline_counts(first.map { |episode| [episode[:classification_at], episode[:start]] }, 24.hours)
    row[:classification_status] = {
      evaluated: first.count { |episode| episode[:classification_status] != 'unevaluated' }, age_basis: 'first_eligible_incoming',
      unevaluated: classification_wait(first, 'unevaluated'), needs_clarification: classification_wait(first, 'uncertain')
    }
    %i[first_response subsequent_response].each { |key| row[key] = metrics(row[key], inbox) }
    row
  end

  def classification_wait(episodes, status)
    ages = episodes.select { |episode| episode[:classification_status] == status }.map { |episode| @as_of - episode[:start] }
    { count: ages.size, calendar_age_seconds: distribution(ages) }
  end

  def metrics(episodes, inbox)
    completed, unresolved = episodes.partition { |episode| episode[:finish] }
    calendar = completed.map { |episode| episode[:finish] - episode[:start] }
    ages = unresolved.map { |episode| @as_of - episode[:start] }
    business = if inbox.working_hours_enabled?
                 episodes.index_with { |episode| business_seconds(inbox, episode[:start], episode[:finish] || @as_of) }
               end
    { eligible: episodes.size, responded: completed.size, response_rate: ratio(completed.size, episodes.size),
      response_rate_target_met: episodes.empty? ? nil : completed.size * 100 > episodes.size * 95,
      completed_calendar_seconds: distribution(calendar),
      completed_business_seconds: business ? distribution(completed.map { |episode| business[episode] }) : nil,
      unresolved: { count: unresolved.size, calendar_age_seconds: distribution(ages),
                    business_age_seconds: business ? distribution(unresolved.map { |ep| business[ep] }) : nil },
      sla: sla_counts(episodes, business) }
  end

  def sla_counts(episodes, business)
    return { status: 'unavailable', eligible: nil, met: nil, missed: nil, pending: nil, ratio: nil } unless business

    met = episodes.count { |episode| episode[:finish] && business[episode] <= 300 }
    pending = episodes.count { |episode| !episode[:finish] && business[episode] < 300 }
    eligible = episodes.size - pending
    { status: 'available', eligible: eligible, met: met, missed: eligible - met, pending: pending, ratio: ratio(met, eligible) }
  end

  def deadline_counts(pairs, threshold)
    met = pairs.count { |finish, start| finish && finish - start <= threshold }
    pending = pairs.count { |finish, start| !finish && @as_of - start < threshold }
    eligible = pairs.size - pending
    { eligible: eligible, met: met, missed: eligible - met, pending: pending, ratio: ratio(met, eligible) }
  end

  def distribution(values)
    sorted = values.sort
    count = sorted.size
    return { n: 0, mean: nil, median: nil, p90: nil } if count.zero?

    median = count.odd? ? sorted[count / 2] : (sorted[(count / 2) - 1] + sorted[count / 2]) / 2.0
    { n: count, mean: sorted.sum / count.to_f, median: median, p90: sorted[(count * 0.9).ceil - 1] }
  end

  def ratio(numerator, denominator)
    denominator.zero? ? nil : numerator.to_f / denominator
  end

  def business_seconds(inbox, from, to)
    zone = ActiveSupport::TimeZone[inbox.timezone]
    raise ArgumentError, 'Invalid inbox timezone' unless zone

    hours = inbox.working_hours.index_by(&:day_of_week)
    raise ArgumentError, 'Incomplete inbox working hours' unless hours.keys.sort == (0..6).to_a

    # Local calendar boundaries preserve DST and fractional seconds without changing shared WorkingHours configuration.
    (from.in_time_zone(zone).to_date..to.in_time_zone(zone).to_date).sum do |date|
      day = hours.fetch(date.wday)
      next 0 if day.closed_all_day?

      opens = zone.local(date.year, date.month, date.day, day.open_hour, day.open_minutes)
      closes = if day.open_all_day?
                 following = date + 1.day
                 zone.local(following.year, following.month, following.day)
               else
                 zone.local(date.year, date.month, date.day, day.close_hour, day.close_minutes)
               end
      [[to, closes].min - [from, opens].max, 0].max
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
