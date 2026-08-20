# frozen_string_literal: true

# UMI runs WhatsApp on a number another platform provisioned and still owns, with Chatwoot
# added afterwards as a second app subscribed to the same WABA. Inert unless a channel opts
# in with `provider_config['umi_foreign_owned'] = true`.
#
# See docs/UMI-SHARED-NUMBER-SPEC.md §2.1 for which guards this implements and which the
# live per-app experiment made unnecessary.
Rails.application.reloader.to_prepare do
  channel = Channel::Whatsapp
  setup_service = Whatsapp::WebhookSetupService

  unless channel.private_method_defined?(:should_auto_setup_webhooks?) && channel.method_defined?(:enable_voice_calling!)
    raise 'UMI zz_umi_foreign_owned_whatsapp: Channel::Whatsapp contract changed — rebase the patch'
  end

  # build_callback_url is private, and the operator rake task reads it to print the URL that
  # must be pasted into the Meta dashboard — losing it would break the only supported setup path.
  unless setup_service.method_defined?(:perform) && setup_service.method_defined?(:register_callback) &&
         setup_service.private_method_defined?(:register_phone_number) &&
         setup_service.private_method_defined?(:build_callback_url)
    raise 'UMI zz_umi_foreign_owned_whatsapp: Whatsapp::WebhookSetupService contract changed — rebase the patch'
  end

  channel.prepend(Umi::Channel::ForeignOwnedWhatsapp) unless channel.ancestors.include?(Umi::Channel::ForeignOwnedWhatsapp)
  setup_service.prepend(Umi::Whatsapp::ForeignOwnedWebhookSetup) unless setup_service.ancestors.include?(Umi::Whatsapp::ForeignOwnedWebhookSetup)
end
