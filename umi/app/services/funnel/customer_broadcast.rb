# frozen_string_literal: true

module Umi::Funnel::CustomerBroadcast
  private

  def broadcast(account, tokens, event_name, data)
    customer_tokens = ContactInbox.where(pubsub_token: tokens).pluck(:pubsub_token)
    super(account, tokens - customer_tokens, event_name, data)
    return if customer_tokens.empty?

    payload = data.merge(account_id: account.id)
    payload[:performer] = Current.user.push_event_data if Current.user.present?
    ActionCableBroadcastJob.perform_later(customer_tokens.uniq, event_name, Umi::Funnel::CustomerPayload.filter(payload))
  end
end
