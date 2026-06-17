# frozen_string_literal: true

# UMI patch: enqueue a Shopify sync whenever a Help Center article changes.
# Included into Article by config/initializers/zz_umi_shopify_help_center.rb.
module Umi::ShopifyHelpCenterSyncable
  extend ActiveSupport::Concern

  included do
    after_commit :umi_enqueue_help_center_sync, on: %i[create update]
    after_commit :umi_enqueue_help_center_delete, on: :destroy
  end

  private

  # Only the configured portal + locale mirror to Shopify. Filtering locale keeps
  # non-en translations — which would slugify to a colliding handle — out of the
  # sync (source of truth is the en FAQ).
  def umi_help_center_syncable?
    portal&.slug.present? &&
      portal.slug == ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help') &&
      locale.to_s == ENV.fetch('UMI_HC_LOCALE', 'en')
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
    return unless umi_help_center_syncable?

    event = status.to_s == 'published' ? 'upserted' : 'unpublished'
    Umi::Shopify::HelpCenterSyncJob.perform_later(umi_help_center_attrs(event))
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
  end

  def umi_enqueue_help_center_delete
    return unless umi_help_center_syncable?

    Umi::Shopify::HelpCenterSyncJob.perform_later(umi_help_center_attrs('deleted'))
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
  end
end
