# UMI patch. Fixes two Facebook Messenger defaults broken in Chatwoot for new Meta apps:
#  1) the bundled facebook-messenger gem hardcodes the removed Graph API v3.2 -> v21.0
#  2) outbound replies should use the 'HUMAN_AGENT' message tag (Meta's 7-day
#     human-agent window) rather than the default 'RESPONSE'. Chatwoot's OSS service
#     already implements this behind ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT
#     (Facebook::SendOnFacebookService#merge_human_agent_tag, and the Instagram
#     equivalent) — so we just turn the flag on instead of overriding the service.
#     Skipped in test so the upstream default-RESPONSE specs are unaffected.
ENV['ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT'] ||= 'true' unless Rails.env.test?

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
