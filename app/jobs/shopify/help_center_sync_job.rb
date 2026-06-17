# frozen_string_literal: true

# UMI patch: runs one Help Center article change against Shopify, off the
# request/save path. Idempotent — safe to retry.
class Shopify::HelpCenterSyncJob < ApplicationJob
  queue_as :low

  def perform(attrs)
    Shopify::HelpCenterSyncService.new(attrs).perform
  end
end
