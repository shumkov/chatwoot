# frozen_string_literal: true

module Umi::Shopify::CloudProductDelivery
  private

  def product_policy_hold
    return 'Cloud product shares are not activated.' unless channel.provider == 'whatsapp_cloud'
    return 'Cloud product shares are not activated.' unless ENV['UMI_PRODUCT_SHARES_CLOUD_ENABLED'] == 'true'
    return 'The WhatsApp session window is closed.' unless conversation.can_reply?

    nil
  end

  def product_service_principal?
    message.sender.is_a?(User) && message.sender_id.to_s == ENV['UMI_COMMERCE_BRIDGE_USER_ID'] &&
      conversation.account_id == ENV.fetch('UMI_COMMERCE_ACCOUNT_ID', '1').to_i &&
      conversation.inbox_id == ENV.fetch('UMI_COMMERCE_CLOUD_INBOX_ID', '3').to_i
  end

  def product_provider_call
    channel.provider_service.send_product_share(contact_inbox.source_id, message)
  end
end
