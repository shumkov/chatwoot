# frozen_string_literal: true

module Umi::Funnel::MessageCapture
  extend ActiveSupport::Concern
  included do
    after_create_commit :capture_umi_funnel_message
  end

  private

  def capture_umi_funnel_message
    Umi::Funnel::EventRecorder.capture_message(self)
  rescue StandardError => e
    Rails.logger.error("[umi-funnel] message capture failed: #{e.class}")
  end
end
