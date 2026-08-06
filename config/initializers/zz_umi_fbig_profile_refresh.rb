# frozen_string_literal: true

# UMI patch: nightly FB/IG contact profile enrichment — fills in the names,
# handles and avatars Meta withheld when a contact was first created, which
# Chatwoot never revisits (the profile fetch is one-shot at contact creation
# on both platforms). Design + review record:
# docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md. App code:
#   umi/app/services/fbig/profile_enrichment_service.rb
#   umi/app/jobs/fbig/profile_refresh_job.rb
#   umi/app/models/profile_ledger_entry.rb
#
# Config: UMI_FBIG_PROFILE_REFRESH_DISABLED=true — kill switch.
#
# apply/cap are job arguments rather than env: a cron whose writes are gated
# on an env flag needs that flag permanently set to do anything, at which
# point it guards nothing. The supervised backlog drain is the same job
# invoked directly with a raised cap.
#
# remove-when: upstream re-fetches contact profile data after contact
# creation, so these gaps self-heal without a sweep.

# Cron registration. MUST use per-job create/destroy, never
# Sidekiq::Cron::Job.load_from_hash!: that method's purge filter is hardcoded
# to jobs tagged source "schedule", so a second load_from_hash! call would
# destroy the entire core schedule.yml schedule on every Sidekiq boot.
Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  if ENV['UMI_FBIG_PROFILE_REFRESH_DISABLED'] == 'true'
    # Cron jobs persist in Redis; disabling the flag must remove the job or a
    # zombie schedule keeps firing against Meta.
    Sidekiq::Cron::Job.destroy('umi_fbig_profile_refresh')
  else
    job = Sidekiq::Cron::Job.new(
      name: 'umi_fbig_profile_refresh',
      # 21:15 UTC = 04:15 Bangkok. Offset from recon's 20:30 so the two do not
      # contend for the same page token.
      cron: '15 21 * * *',
      class: 'Umi::Fbig::ProfileRefreshJob',
      args: [{ 'apply' => true }],
      queue: 'low',
      source: 'umi'
    )
    unless job.save
      message = "[UMI-FBIG] profile refresh cron registration FAILED: #{job.errors.join('; ')}"
      ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
      Rails.logger.error(message)
    end
  end
end
