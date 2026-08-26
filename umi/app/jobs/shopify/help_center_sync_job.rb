# frozen_string_literal: true

# UMI patch: runs one Help Center article change against Shopify, off the
# request/save path. Idempotent — safe to retry.
#
# The source locale becomes a Shopify article; every other locale the sync
# accepts becomes a translation of that article, which is a different API
# surface (GraphQL translationsRegister) and so a different service.
class Umi::Shopify::HelpCenterSyncJob < ApplicationJob
  queue_as :low

  def perform(attrs)
    service = service_for(attrs)
    return log_unroutable(attrs) if service.nil?

    service.new(attrs).perform
  end

  private

  # Three-way on purpose rather than "source, else translation". The two
  # mistakes are not symmetric: routing an unrecognised locale to the article
  # sync would mint a second Shopify article competing for the English handle,
  # which is the exact failure the old locale gate existed to prevent. Anything
  # this does not recognise is dropped with a log instead.
  def service_for(attrs)
    locale = attrs.is_a?(Hash) ? (attrs['locale'] || attrs[:locale]) : nil
    return Umi::Shopify::HelpCenterSyncService if Umi::Shopify::HelpCenterLocales.source?(locale)
    return Umi::Shopify::ArticleTranslationSyncService if Umi::Shopify::HelpCenterLocales.translation?(locale)

    nil
  end

  def log_unroutable(attrs)
    Rails.logger.warn("[umi-hc-sync] no service for locale #{attrs.try(:[], 'locale').inspect} " \
                      "(article #{attrs.try(:[], 'id')}) — dropped")
  end
end
