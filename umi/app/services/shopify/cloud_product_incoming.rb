# frozen_string_literal: true

module Umi::Shopify::CloudProductIncoming
  private

  def create_regular_message(message)
    return super if outgoing_echo

    return create_catalog_order(message) if message_type == 'order'

    super
    annotate_product_enquiry(message)
  end

  def create_catalog_order(message)
    order = message[:order].is_a?(Hash) ? message[:order] : {}
    items = catalog_items(order)
    create_message(message, source_id: message[:id])
    @message.content = catalog_order_content(order, items)
    @message.content_attributes = @message.content_attributes.merge('umi_whatsapp_catalog' =>
      { 'kind' => 'order', 'catalog_id' => order[:catalog_id].to_s, 'items' => items, 'mapped' => false })
    @message.save!
  end

  def catalog_items(order)
    Array(order[:product_items]).map do |item|
      item = {} unless item.is_a?(Hash)
      { 'retailer_id' => item[:product_retailer_id].to_s, 'quantity' => item[:quantity].to_s }
    end
  end

  def catalog_order_content(order, items)
    lines = ['WhatsApp catalog order received. No Shopify order or payment was created.',
             "Catalog: #{order[:catalog_id].presence || 'unknown'}"]
    lines += items.map { |item| "Product #{item['retailer_id'].presence || 'unknown'} × #{item['quantity'].presence || 'unknown'}" }
    lines << 'Item details unavailable.' if items.empty?
    lines << order[:text].to_s if order[:text].present?
    lines.join("\n")
  end

  def annotate_product_enquiry(message)
    context = message[:context]
    referred = context[:referred_product] if context.is_a?(Hash)
    return unless referred.is_a?(Hash)

    catalog_id = referred[:catalog_id].to_s
    retailer_id = referred[:product_retailer_id].to_s
    detail = "Product enquiry: catalog #{catalog_id.presence || 'unknown'}, product #{retailer_id.presence || 'unknown'}."
    @message.content = [@message.content, detail].compact.join("\n")
    @message.content_attributes = @message.content_attributes.merge('umi_whatsapp_catalog' =>
      { 'kind' => 'enquiry', 'catalog_id' => catalog_id, 'retailer_id' => retailer_id, 'mapped' => false })
    @message.save!
  end
end
