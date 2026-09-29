# frozen_string_literal: true

module Umi::Funnel::MessageCapture
  extend ActiveSupport::Concern
  included do
    after_create_commit :capture_umi_funnel_message
  end

  private

  def capture_umi_funnel_message
    Umi::Funnel::EventRecorder.capture_message(self)
    if incoming? && !private? && Umi::Funnel::CustomerContextSync.refreshable?(conversation.contact)
      Umi::Funnel::ProfileSyncJob.perform_later(conversation.contact_id, force: true)
    end
  rescue StandardError => e
    Rails.logger.error("[umi-funnel] message capture failed: #{e.class}")
  end
end
