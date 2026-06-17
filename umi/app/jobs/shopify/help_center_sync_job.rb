# frozen_string_literal: true

# UMI patch: runs one Help Center article change against Shopify, off the
# request/save path. Idempotent — safe to retry.
class Umi::Shopify::HelpCenterSyncJob < ApplicationJob
  queue_as :low

  def perform(attrs)
    Umi::Shopify::HelpCenterSyncService.new(attrs).perform
  end
end
