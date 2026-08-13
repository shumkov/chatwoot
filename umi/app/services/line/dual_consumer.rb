# frozen_string_literal: true

module Umi::Line::DualConsumer
  TARGET_CHANNEL_ID = '2010611374'

  module_function

  def enabled?
    ENV['UMI_LINE_DUAL_CONSUMER_ENABLED'] == 'true'
  end

  def endpoint
    ENV['UMI_LINE_LUMO_WEBHOOK_URL'].presence
  end

  def target_channel_id
    ENV['UMI_LINE_DUAL_CONSUMER_CHANNEL_ID'].presence
  end

  def configured?
    enabled? && endpoint.present? && target_channel_id.present?
  end

  def target_channel?(channel_id)
    configured? && target_channel_id == TARGET_CHANNEL_ID && channel_id.to_s == TARGET_CHANNEL_ID
  end
end
