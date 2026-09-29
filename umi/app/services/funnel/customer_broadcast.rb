# frozen_string_literal: true

module Umi::Funnel::CustomerBroadcast
  private

  def broadcast(account, tokens, event_name, data)
    payload = data.merge(account_id: account.id)
    payload[:performer] = Current.user.push_event_data if Current.user.present?
    customer_payload = Umi::Funnel::CustomerPayload.filter(payload)
    return super if customer_payload == payload

    customer_tokens = ContactInbox.where(pubsub_token: tokens).pluck(:pubsub_token)
    super(account, tokens - customer_tokens, event_name, data)
    return if customer_tokens.empty?

    ActionCableBroadcastJob.perform_later(customer_tokens.uniq, event_name, customer_payload)
  end
end
