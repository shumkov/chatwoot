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

  # Only the configured portal syncs, and within it only two kinds of article:
  # the source locale, which becomes a Shopify article, and the translation
  # locales, which become translations *of* that article. A translation carries
  # no handle of its own, so the handle collision that once kept non-en locales
  # out of the sync does not arise — see docs/UMI-HELP-CENTER-THAI-SPEC.md §3.
  def umi_help_center_syncable?
    portal&.slug.present? &&
      portal.slug == ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help') &&
      (umi_help_center_source_locale? || umi_help_center_translation_locale?)
  end

  def umi_help_center_source_locale?
    Umi::Shopify::HelpCenterLocales.source?(locale)
  end

  # An unlinked translation has no article to translate, so there is nothing to
  # push. Linking it later is an update, which re-fires this callback.
  def umi_help_center_translation_locale?
    Umi::Shopify::HelpCenterLocales.translation?(locale) && associated_article_id.present?
  end

  # A translation is only meaningful against the article it translates, and the
  # Shopify article is found by the *root* article's chatwoot_id.
  def umi_help_center_root_id
    umi_help_center_source_locale? ? id : associated_article_id
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
      'root_id' => umi_help_center_root_id,
      'title' => title,
      'content' => content,
      'description' => description,
      'slug' => slug,
      'status' => status.to_s,
      'position' => position
    }.merge(umi_help_center_category_attrs).merge(umi_help_center_featured_attrs)
  end

  def umi_help_center_category_attrs
    { 'category_name' => category&.name, 'category_slug' => category&.slug }
  end

  def umi_help_center_featured_attrs
    return { 'featured' => false, 'featured_position' => nil } unless meta.is_a?(Hash)

    { 'featured' => meta['featured'].to_s == 'true', 'featured_position' => meta['featured_position'] }
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
