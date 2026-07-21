# frozen_string_literal: true

# UMI patch: Shopify customer → Chatwoot contact sync.
#
# Design + review record: UMI-SHOPIFY-CONTACT-SYNC-SPEC.md (and the
# investigation doc it links). App code lives in the umi/ overlay:
#   umi/app/services/shopify/{client_factory,sync_lock,contact_sync_watermark,
#     customer_contact_mapper,contact_sync_service}.rb
#   umi/app/jobs/shopify/{contact_backfill_job,contact_poll_job}.rb
#   umi/app/controllers/webhooks/shopify_compliance.rb
#   umi/app/controllers/shopify/persist_customer_link.rb
#
# The backfill is started manually: rake umi:shopify_contacts:backfill[account_id].
# The incremental poll cron only registers when UMI_SHOPIFY_CONTACT_SYNC_ENABLED
# is set. The compliance handler and the on-touch customer link are always on
# (compliance + harmless). Config (all optional):
#   UMI_SHOPIFY_CONTACT_SYNC_ENABLED        (unset = poll off)
#   UMI_SHOPIFY_CONTACT_SYNC_CRON           (default */30 * * * *)
#   UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS  (default 20000, backfill ceiling)
#   UMI_SHOPIFY_CONTACT_SYNC_PAGE_WAIT_SECONDS (default 3)
#   UMI_SHOPIFY_CONTACT_SYNC_POLL_MAX_PAGES (default 20)

Rails.application.reloader.to_prepare do
  if defined?(Webhooks::ShopifyController) && Webhooks::ShopifyController.ancestors.exclude?(Umi::Webhooks::ShopifyCompliance)
    Webhooks::ShopifyController.prepend(Umi::Webhooks::ShopifyCompliance)
  end

  if defined?(Api::V1::Accounts::Integrations::ShopifyController) &&
     Api::V1::Accounts::Integrations::ShopifyController.ancestors.exclude?(Umi::Shopify::PersistCustomerLink)
    Api::V1::Accounts::Integrations::ShopifyController.prepend(Umi::Shopify::PersistCustomerLink)
  end
end

# Poll cron registration. MUST use per-job create/destroy, never
# Sidekiq::Cron::Job.load_from_hash!: that method's purge filter is hardcoded to
# jobs tagged source "schedule" regardless of the source: option passed, so a
# second load_from_hash! call would destroy the entire core schedule.yml
# schedule on every Sidekiq boot. A single create with source 'umi' is safe in
# both directions (the core loader's purge ignores non-"schedule" jobs).
Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_SHOPIFY_CONTACT_SYNC_ENABLED', false))
    # sidekiq-cron stores any non-"schedule" source as "dynamic" — which is
    # what Redis will show, and which the core purge ignores either way.
    job = Sidekiq::Cron::Job.new(
      name: 'umi_shopify_contact_poll',
      cron: ENV.fetch('UMI_SHOPIFY_CONTACT_SYNC_CRON', '*/30 * * * *'),
      class: 'Umi::Shopify::ContactPollJob',
      queue: 'low',
      source: 'umi'
    )
    unless job.save
      # A malformed UMI_SHOPIFY_CONTACT_SYNC_CRON would otherwise disable the
      # poll with zero symptoms.
      message = "[umi-contact-sync] poll cron registration FAILED: #{job.errors.join('; ')}"
      ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
      Rails.logger.error(message)
    end
  else
    # Cron jobs persist in Redis; disabling the flag must remove the job or a
    # zombie schedule keeps firing.
    Sidekiq::Cron::Job.destroy('umi_shopify_contact_poll')
  end
end
