# frozen_string_literal: true

# A single Instagram webhook entry can batch several messaging items of
# different event types (e.g. a `read` receipt followed by a `message`).
# Stock Webhooks::InstagramEventsJob#event_name memoizes the first item's
# event type across the loop, so later items are dispatched to the wrong
# handler — a `message` following a `read` is routed to ReadStatusService,
# crashes on the missing `read` key, and the DM is never persisted (Meta
# delivers webhooks only once). Resolve the handler per messaging item.
module Umi::WebhooksInstagramEventDispatch
  private

  def event_name(messaging)
    Webhooks::InstagramEventsJob::SUPPORTED_EVENTS.find { |key| messaging.key?(key) }
  end
end
