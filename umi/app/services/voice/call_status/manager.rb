# frozen_string_literal: true

# The single writer of Call status/timestamps/duration, with terminal-state guards.
# Touches the linked message so the frontend gets a realtime update.
class Umi::Voice::CallStatus::Manager
  def initialize(call:)
    @call = call
  end

  def process(status, duration: nil, timestamp: nil, agent: nil)
    return if status.blank? || @call.status == status || @call.terminal?

    @call.update!(transition_attrs(status, duration, agent, timestamp || Time.current))
    @call.message&.touch # rubocop:disable Rails/SkipsModelValidations
    @call
  end

  private

  def transition_attrs(status, duration, agent, occurred_at)
    attrs = { status: status }
    attrs[:accepted_by_agent] = agent if agent && @call.accepted_by_agent_id.nil?
    attrs[:started_at] = occurred_at if status == 'in_progress' && @call.started_at.nil?
    if Umi::Call::TERMINAL_STATUSES.include?(status)
      attrs[:ended_at] = occurred_at
      attrs[:duration_seconds] = resolved_duration(duration)
    end
    attrs
  end

  def resolved_duration(duration)
    return duration.to_i if duration.present?
    return unless @call.started_at

    (Time.current - @call.started_at).round
  end
end
