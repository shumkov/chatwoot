# frozen_string_literal: true

# Hourly cron entry point for the FB/IG reconciliation
# (docs/UMI-FBIG-RECON-SPEC.md). Registered by
# config/initializers/zz_umi_fbig_recon.rb. Serial Graph HTTP for potentially
# minutes — must not occupy a default-queue worker.
class Umi::Fbig::ConversationReconJob < ApplicationJob
  queue_as :low

  def perform
    # The cron registration honours the kill switch at boot; this guard covers
    # a job that was already enqueued before a disabling restart.
    return if ENV['UMI_FBIG_RECON_DISABLED'] == 'true'

    errors = []
    Channel::FacebookPage.find_each do |channel|
      Umi::Fbig::ConversationReconService.new(channel).perform
    rescue StandardError => e
      # Per-channel isolation: one channel's failure must not stop another's
      # scan. Re-raised below so Sidekiq still retries genuine transients.
      errors << e
    end
    raise errors.first if errors.any?
  end
end
