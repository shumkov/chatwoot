# frozen_string_literal: true

# UMI: one-time (or on-demand) backfill of the Shopify "help" blog from the
# Chatwoot Help Center. The article after_commit hooks only fire on future
# changes, so run this once after connecting the Shopify integration to seed
# every already-published article.
#
#   bundle exec rake umi:help_center:backfill
#
# Idempotent: the sync matches by custom.chatwoot_id, so re-running updates rather
# than duplicates. Jobs are staggered (UMI_HC_BACKFILL_SPACING_SECONDS, default 5s)
# to thin the burst, but each job still makes ~1+N Shopify calls, so a large seed
# can still hit Shopify's REST rate limit; 429s are re-raised and retried by
# Sidekiq, so the backfill is eventually consistent. The per-edit N+1 lookup is a
# known limitation — see UMI-SHOPIFY-HELP-CENTER-SPEC.md §10.
namespace :umi do
  namespace :help_center do
    desc 'Enqueue a Shopify sync for every published Help Center article (seed/repair)'
    task backfill: :environment do
      slug = ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help')
      hc_locale = ENV.fetch('UMI_HC_LOCALE', 'en')
      portal = Portal.find_by(slug: slug)
      abort("Portal '#{slug}' not found") if portal.nil?

      spacing = ENV.fetch('UMI_HC_BACKFILL_SPACING_SECONDS', '5').to_i
      count = 0
      portal.articles.where(status: :published, locale: hc_locale).find_each.with_index do |article, index|
        attrs = article.send(:umi_help_center_attrs, 'upserted')
        Umi::Shopify::HelpCenterSyncJob.set(wait: (index * spacing).seconds).perform_later(attrs)
        count += 1
      end
      puts "Enqueued #{count} published article(s) from portal '#{slug}' (locale #{hc_locale}) for Shopify sync, spaced #{spacing}s apart."
    end
  end
end
