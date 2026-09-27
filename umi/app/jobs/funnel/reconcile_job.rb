# frozen_string_literal: true

class Umi::Funnel::ReconcileJob < ApplicationJob
  queue_as :low

  def perform
    ids = Umi::Funnel::Configuration.account_ids
    return if ids.empty?

    Umi::Funnel::Privacy.redact_orphans!
    Account.where(id: ids).find_each { |account| Umi::Funnel::Configuration.provision!(account) }
    Message.where(account_id: ids, message_type: :incoming, private: false)
           .where('created_at >= ?', Umi::Funnel::Configuration.started_at).find_each do |message|
      Umi::Funnel::EventRecorder.capture_message(message)
    end
    Umi::Funnel::PaidCustomerLink.reconcile
    Umi::Funnel::DeliveryAutomation.enqueue
    Umi::ShopifyOrderFinancialState.pending.where(account_id: ids, redacted_at: nil, last_error: nil).find_each do |state|
      Umi::Shopify::OrderFinancialReconcileJob.perform_later(state.id)
    end
  end
end
