# frozen_string_literal: true

# UMI patch: a website visitor holds only the public website token, so a
# Shopify customer id or other sync-owned key it sends through the widget
# contact endpoint is a claim nobody verified. Drop those keys from the
# visitor's additional_attributes before ContactIdentifyAction merges them;
# keys the contact already carries are untouched.
module Umi::Shopify::WidgetContactKeys
  private

  def permitted_params
    values = super
    attributes = values[:additional_attributes]
    values[:additional_attributes] = attributes.except(*Umi::Shopify::CustomerContactMapper::SHOPIFY_KEYS) if attributes
    values
  end
end
