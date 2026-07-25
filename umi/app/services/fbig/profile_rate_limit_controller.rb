# frozen_string_literal: true

class Umi::Fbig::ProfileRateLimitController
  class WaitBudgetError < StandardError; end
  class LockLossError < StandardError; end

  RETRY_WAIT_SECONDS = [60, 300, 900].freeze
  PREVENTIVE_THRESHOLD = 80
  PREVENTIVE_WAIT_SECONDS = 60
  MAX_WAIT_SLICE_SECONDS = 60
  SERVER_WAIT_JITTER_RANGE = 0..5

  attr_reader :waited_seconds, :maximum_percent, :maximum_estimated_regain_minutes

  def initialize(max_wait_seconds:, sleeper:, renewer:, random: Random)
    @max_wait_seconds = max_wait_seconds
    @sleeper = sleeper
    @renewer = renewer
    @random = random
    @waited_seconds = 0
    @preventive_wait_seconds = 0
    @server_regain_wait_seconds = 0
    @maximum_percent = 0
    @maximum_estimated_regain_minutes = 0
  end

  def observe(usage)
    @maximum_percent = [@maximum_percent, usage.maximum_percent.to_f].max
    @maximum_estimated_regain_minutes = [
      @maximum_estimated_regain_minutes,
      usage.estimated_regain_minutes.to_f
    ].max
    regain_seconds = usage.estimated_regain_minutes.to_f * 60
    @server_regain_wait_seconds = regain_seconds.ceil if regain_seconds.positive?
    @preventive_wait_seconds = PREVENTIVE_WAIT_SECONDS if usage.maximum_percent.to_f >= PREVENTIVE_THRESHOLD
  end

  def before_request!
    seconds = @preventive_wait_seconds
    @preventive_wait_seconds = 0
    @server_regain_wait_seconds = 0
    wait!(seconds) if seconds.positive?
  end

  def retry_wait!(attempt)
    seconds = if @server_regain_wait_seconds.positive?
                @server_regain_wait_seconds + @random.rand(SERVER_WAIT_JITTER_RANGE)
              else
                RETRY_WAIT_SECONDS.fetch(attempt - 1)
              end
    @server_regain_wait_seconds = 0
    @preventive_wait_seconds = 0
    wait!(seconds)
  rescue IndexError
    raise WaitBudgetError
  end

  private

  def wait!(seconds)
    raise WaitBudgetError if @waited_seconds + seconds > @max_wait_seconds

    remaining = seconds
    while remaining.positive?
      slice = [remaining, MAX_WAIT_SLICE_SECONDS].min
      raise LockLossError unless @renewer.call

      @sleeper.call(slice)
      @waited_seconds += slice
      remaining -= slice
    end
  end
end
