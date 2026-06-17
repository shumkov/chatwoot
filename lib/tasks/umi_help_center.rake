# frozen_string_literal: true

# UMI: one-time (or on-demand) backfill of the Shopify "help" blog from the
# Chatwoot Help Center. The article after_commit hooks only fire on future
# changes, so run this once after connecting the Shopify integration to seed
# every already-published article.
#
#   bundle exec rake umi:help_center:backfill
#
# Idempotent: the sync matches by custom.chatwoot_id, so re-running updates
# rather than duplicates.
namespace :umi do
  namespace :help_center do
    desc 'Enqueue a Shopify sync for every published Help Center article (seed/repair)'
    task backfill: :environment do
      slug = ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help')
      portal = Portal.find_by(slug: slug)
      abort("Portal '#{slug}' not found") if portal.nil?

      count = 0
      portal.articles.where(status: :published).find_each do |article|
        article.send(:umi_enqueue_help_center_sync)
        count += 1
      end
      puts "Enqueued #{count} published article(s) from portal '#{slug}' for Shopify sync."
    end
  end
end
