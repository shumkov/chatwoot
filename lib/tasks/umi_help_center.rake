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
#
# The non-English locales have their own tasks in umi_help_center_translations.rake:
# they land on the same Shopify articles as translations, not as articles of their
# own — see docs/UMI-HELP-CENTER-THAI-SPEC.md.

# Shared by both help-center rake files.
def umi_hc_portal
  slug = ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help')
  portal = Portal.find_by(slug: slug)
  abort("Portal '#{slug}' not found") if portal.nil?
  portal
end

def umi_hc_translation_locale(argument)
  locale = argument.presence || Umi::Shopify::HelpCenterLocales.translations.first
  abort('No translation locale given and UMI_HC_TRANSLATION_LOCALES is empty') if locale.blank?
  locale
end

# Enqueue one sync job per article, spaced out so a seed does not burst into
# Shopify's rate limit.
def umi_hc_enqueue_all(articles)
  spacing = ENV.fetch('UMI_HC_BACKFILL_SPACING_SECONDS', '5').to_i
  count = 0
  articles.find_each.with_index do |article, index|
    attrs = article.send(:umi_help_center_attrs, 'upserted')
    Umi::Shopify::HelpCenterSyncJob.set(wait: (index * spacing).seconds).perform_later(attrs)
    count += 1
  end
  [count, spacing]
end

namespace :umi do
  namespace :help_center do
    desc 'Enqueue a Shopify sync for every published Help Center article (seed/repair)'
    task backfill: :environment do
      portal = umi_hc_portal
      locale = Umi::Shopify::HelpCenterLocales.source
      count, spacing = umi_hc_enqueue_all(portal.articles.where(status: :published, locale: locale))

      puts "Enqueued #{count} published article(s) from portal '#{portal.slug}' (locale #{locale}) " \
           "for Shopify sync, spaced #{spacing}s apart."
    end
  end
end
