# frozen_string_literal: true

# UMI patch: hourly FB/IG message reconciliation against Meta's Conversations
# API — detects (and, with UMI_FBIG_RECON_HEAL=true, replays) messages Meta
# has but Chatwoot doesn't, the class no webhook-side code can see. The cadence
# bounds how long a customer waits invisibly: the scan window in the service is
# sized to it, so the two must change together.
# Design + review record: docs/UMI-FBIG-RECON-SPEC.md. App code:
#   umi/app/services/fbig/{conversation_recon_service,message_heal_service}.rb
#   umi/app/jobs/fbig/conversation_recon_job.rb
#
# Config: UMI_FBIG_RECON_DISABLED=true  — kill switch (default: enabled;
#           read-only observability, same default posture as zz_umi_fbig_trace)
#         UMI_FBIG_RECON_HEAL=true      — enable inbound auto-heal (default off)
#
# remove-when: upstream ships webhook-delivery reconciliation for Meta
# channels, or Meta provides delivery guarantees/replay.

# Cron registration. MUST use per-job create/destroy, never
# Sidekiq::Cron::Job.load_from_hash!: that method's purge filter is hardcoded
# to jobs tagged source "schedule", so a second load_from_hash! call would
# destroy the entire core schedule.yml schedule on every Sidekiq boot.
Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  if ENV['UMI_FBIG_RECON_DISABLED'] == 'true'
    # Cron jobs persist in Redis; disabling the flag must remove the job or a
    # zombie schedule keeps firing.
    Sidekiq::Cron::Job.destroy('umi_fbig_recon')
  else
    job = Sidekiq::Cron::Job.new(
      name: 'umi_fbig_recon',
      cron: '0 * * * *', # hourly — a message Meta never delivered reaches the agent within the hour
      class: 'Umi::Fbig::ConversationReconJob',
      queue: 'low',
      source: 'umi'
    )
    unless job.save
      message = "[UMI-FBIG] recon cron registration FAILED: #{job.errors.join('; ')}"
      ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
      Rails.logger.error(message)
    end
  end
end
