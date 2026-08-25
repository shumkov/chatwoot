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
    service_for(attrs).new(attrs).perform
  end

  private

  def service_for(attrs)
    locale = attrs.is_a?(Hash) ? (attrs['locale'] || attrs[:locale]) : nil
    if Umi::Shopify::HelpCenterLocales.source?(locale)
      Umi::Shopify::HelpCenterSyncService
    else
      Umi::Shopify::ArticleTranslationSyncService
    end
  end
end
