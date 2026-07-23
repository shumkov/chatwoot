# frozen_string_literal: true

# UMI patch: name new Facebook contacts from the Conversations API when the
# profile API is denied.
#
# Meta's /PSID User Profile API answers only for apps holding the Business
# Asset User Profile Access feature (App Review submitted 2026-07-23, pending)
# and denies pre-app-connection threads outright — upstream then names the
# contact "John Doe" forever. Umi::FacebookContactNameFallback resolves the
# name via the page-inbox Conversations API participants field instead
# (permissions the app already holds; the same source Business Suite shows).
#
# remove-when: Business Asset User Profile Access is granted AND the profile
# API resolves all new senders in practice (watch for
# stage=participant_name_used lines going quiet), or upstream ships an
# equivalent fallback.

Rails.application.reloader.to_prepare do
  unless Messages::Facebook::MessageBuilder.private_method_defined?(:process_contact_params_result)
    raise 'UMI zz_umi_fb_contact_name_fallback: Messages::Facebook::MessageBuilder#process_contact_params_result no longer exists — rebase the patch.'
  end

  unless Messages::Facebook::MessageBuilder.include?(Umi::FacebookContactNameFallback)
    Messages::Facebook::MessageBuilder.prepend(Umi::FacebookContactNameFallback)
  end
end
