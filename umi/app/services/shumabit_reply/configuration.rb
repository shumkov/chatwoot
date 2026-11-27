# frozen_string_literal: true

# Loader settings. Only an absent InstallationConfig means off; a present but invalid one disables every Suggest reply
# answer instead of falling back to native generation, so a typo can never send a listed inbox to a model.
class Umi::ShumabitReply::Configuration
  NAME = 'UMI_SHUMABIT_REPLY'
  DEFAULT_WAIT_SECONDS = 40
  # The hold must end inside the proxy's 50-second response ceiling.
  MAX_WAIT_SECONDS = 45

  def self.current
    record = InstallationConfig.find_by(name: NAME)
    new(record&.value, present: !record.nil?)
  end

  def initialize(value, present:)
    @value = value
    @present = present
  end

  # A stored row with an empty or malformed value is present, so it is invalid rather than off.
  def off?
    !@present
  end

  def valid? # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return false unless @value.is_a?(Hash)

    inbox_ids = @value['inbox_ids']
    cutoff = @value['eligible_after_ms']
    inbox_ids.is_a?(Array) && inbox_ids.all? { |id| id.is_a?(Integer) && id.positive? } &&
      cutoff.is_a?(Integer) && !cutoff.negative? && wait_seconds.is_a?(Integer) && wait_seconds.between?(1, MAX_WAIT_SECONDS)
  end

  def listed?(inbox_id)
    valid? && @value['inbox_ids'].include?(inbox_id)
  end

  # The bridge's cutoff is a millisecond instant; message timestamps compare in whole seconds, as the bridge floors it.
  def eligible_after
    @value['eligible_after_ms'] / 1000
  end

  def wait_seconds
    @value.fetch('wait_seconds', DEFAULT_WAIT_SECONDS)
  end

  def bridge_url
    ENV.fetch('UMI_SHUMABIT_BRIDGE_URL', nil).presence
  end

  def bridge_user_id
    value = ENV.fetch('UMI_COMMERCE_BRIDGE_USER_ID', nil).to_s
    value.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
  end

  def ready?
    bridge_url.present? && bridge_user_id.present?
  end
end
