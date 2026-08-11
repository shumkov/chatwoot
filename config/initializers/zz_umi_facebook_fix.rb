# UMI patch. Repoints the bundled facebook-messenger gem off the removed Graph
# API v3.2 onto v21.0.
#
# This initializer used to also set ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT, to put
# outbound replies in Meta's 7-day human-agent window instead of the default
# 24-hour RESPONSE window. That never took effect: GlobalConfigService reads
# InstallationConfig before ENV, and this installation holds an explicit `false`
# there, so the flag was a no-op.
#
# It is deliberately not revived. When the flag is on, merge_human_agent_tag
# stamps messaging_type=MESSAGE_TAG + tag=HUMAN_AGENT on *every* outbound
# message, not only those past the 24-hour mark — so if Meta has not granted the
# app the human_agent permission, all outbound messaging fails. Measured
# benefit: 4 replies in 60 days went out later than 24 hours, and 3 of those
# were an internal test conversation. Wrong side of that trade.
#
# To enable it properly: confirm the human_agent permission is granted for the
# app, then set the InstallationConfig row — not ENV, which loses.

Rails.application.config.after_initialize do
  # Don't repoint FB URLs under test — the suite stubs the gem's default base_uri.
  next if Rails.env.test?
  next unless defined?(Facebook::Messenger)

  graph = 'https://graph.facebook.com/v21.0/me'
  [Facebook::Messenger::Bot,
   Facebook::Messenger::Profile,
   Facebook::Messenger::Subscriptions].each do |klass|
    opts = klass.instance_variable_get(:@default_options) || {}
    opts[:base_uri] = graph
    klass.instance_variable_set(:@default_options, opts)
  end
  Rails.logger.info("[fb-api-version] facebook-messenger base_uri pinned to #{graph}")
end
