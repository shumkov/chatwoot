# frozen_string_literal: true

# UMI patch: dispatch each Instagram webhook messaging item to its own handler.
#
# Stock Webhooks::InstagramEventsJob#event_name memoizes the first item's event
# type (`@event_name ||= ...`) across the messaging loop, so a batch mixing
# `read` + `message` items routes later items to the first item's handler and
# loses the message (webhooks are delivered once — the DM is gone permanently).
# Umi::WebhooksInstagramEventDispatch resolves the event per item instead.
#
# remove-when: upstream drops the memoization in
# Webhooks::InstagramEventsJob#event_name (chatwoot/chatwoot).

Rails.application.reloader.to_prepare do
  unless Webhooks::InstagramEventsJob.private_method_defined?(:event_name) &&
         Webhooks::InstagramEventsJob.const_defined?(:SUPPORTED_EVENTS)
    raise 'UMI zz_umi_ig_event_dispatch_fix: Webhooks::InstagramEventsJob#event_name / SUPPORTED_EVENTS no longer exist — rebase the patch.'
  end

  unless Webhooks::InstagramEventsJob.include?(Umi::WebhooksInstagramEventDispatch)
    Webhooks::InstagramEventsJob.prepend(Umi::WebhooksInstagramEventDispatch)
  end
end
