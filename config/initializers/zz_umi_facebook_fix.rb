# Managed by Ansible. Mounted into the Chatwoot rails + sidekiq containers at
# /app/config/initializers/zz_fb_api_version.rb.
#
# Fixes two Facebook Messenger defaults broken in Chatwoot for new Meta apps:
#  1) bundled facebook-messenger gem hardcodes the removed Graph API v3.2 -> v21.0
#  2) outbound replies use the deprecated 'ACCOUNT_UPDATE' message tag (Meta
#     subcode 1893061) -> 'HUMAN_AGENT' (correct 7-day human-agent window)
Rails.application.config.after_initialize do
  if defined?(Facebook::Messenger)
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

  if defined?(Facebook::SendOnFacebookService)
    module FacebookSendTagFix
      def fb_text_message_params
        {
          recipient: { id: contact.get_source_id(inbox.id) },
          message: fb_text_message_payload,
          messaging_type: 'MESSAGE_TAG',
          tag: 'HUMAN_AGENT'
        }
      end

      def fb_attachment_message_params(attachment)
        {
          recipient: { id: contact.get_source_id(inbox.id) },
          message: {
            attachment: {
              type: attachment_type(attachment),
              payload: { url: attachment.download_url }
            }
          },
          messaging_type: 'MESSAGE_TAG',
          tag: 'HUMAN_AGENT'
        }
      end
    end
    Facebook::SendOnFacebookService.prepend(FacebookSendTagFix)
    Rails.logger.info('[fb-api-version] SendOnFacebookService patched: ACCOUNT_UPDATE -> HUMAN_AGENT')
  end
end
