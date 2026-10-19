# frozen_string_literal: true

module Umi::Shopify::CloudProductProvider
  def send_product_share(phone_number, message)
    card = message.content_attributes.fetch('umi_product_card')
    image_url = card['image_url']
    body = { messaging_product: 'whatsapp', recipient_type: 'individual', to: phone_number }
    if image_url.present?
      body[:type] = 'image'
      body[:image] = { link: image_url, caption: message.content }
    else
      body[:type] = 'text'
      body[:text] = { body: message.content }
    end
    response = HTTParty.post("#{phone_id_path('v24.0')}/messages", headers: api_headers, body: body.to_json, timeout: 30)
    product_share_response(response)
  end

  private

  def product_share_response(response)
    parsed = response.parsed_response
    return { 'message_id' => parsed.dig('messages', 0, 'id') } if response.success? && parsed.is_a?(Hash) && parsed['error'].blank?
    return { 'error' => parsed['error'] } if parsed.is_a?(Hash) && parsed['error'].present?

    {}
  end
end
