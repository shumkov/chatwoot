# frozen_string_literal: true

# These upstream jobs run for every dispatched event and ActionCable broadcast, thousands of
# times an hour. Their arguments carry whole event payloads, changed attributes and ActionCable
# pubsub tokens, so logging them fills the journal and copies customer data into it. Job class,
# id, queue, timing and failures are still logged.
Rails.application.reloader.to_prepare do
  [EventDispatcherJob, ActionCableBroadcastJob].each { |job| job.log_arguments = false }
end
