# frozen_string_literal: true

class Umi::Shopify::OrderFinancialReconcileJob < ApplicationJob
  queue_as :low

  def perform(state_id)
    state = Umi::ShopifyOrderFinancialState.find_by(id: state_id)
    Umi::Shopify::OrderFinancialStateService.new(state).perform if state
  end
end
