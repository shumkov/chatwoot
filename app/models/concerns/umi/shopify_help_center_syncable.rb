# frozen_string_literal: true

# UMI patch: enqueue a Shopify sync whenever a Help Center article changes.
# Included into Article by config/initializers/zz_umi_shopify_help_center.rb.
module Umi
  module ShopifyHelpCenterSyncable
    extend ActiveSupport::Concern

    included do
      after_commit :umi_enqueue_help_center_sync, on: %i[create update]
      after_commit :umi_enqueue_help_center_delete, on: :destroy
    end

    private

    def umi_help_center_portal?
      portal&.slug.present? && portal.slug == ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help')
    end

    # Snapshot the fields the sync needs, so the job is self-contained and works
    # even for deletes (where the record no longer exists by the time it runs).
    def umi_help_center_attrs(event)
      {
        'event' => event,
        'id' => id,
        'account_id' => account_id,
        'portal_slug' => portal&.slug,
        'locale' => locale,
        'title' => title,
        'content' => content,
        'description' => description,
        'slug' => slug,
        'status' => status.to_s,
        'position' => position,
        'category_name' => category&.name,
        'category_slug' => category&.slug
      }
    end

    def umi_enqueue_help_center_sync
      return unless umi_help_center_portal?

      event = status.to_s == 'published' ? 'upserted' : 'unpublished'
      Shopify::HelpCenterSyncJob.perform_later(umi_help_center_attrs(event))
    rescue StandardError => e
      Rails.logger.error("[umi-hc-sync] enqueue failed for article #{id}: #{e.message}")
    end

    def umi_enqueue_help_center_delete
      return unless umi_help_center_portal?

      Shopify::HelpCenterSyncJob.perform_later(umi_help_center_attrs('deleted'))
    rescue StandardError => e
      Rails.logger.error("[umi-hc-sync] delete-enqueue failed for article #{id}: #{e.message}")
    end
  end
end
