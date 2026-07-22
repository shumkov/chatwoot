# frozen_string_literal: true

# UMI patch: persist Instagram DMs even when the sender profile fetch fails.
#
# Stock Instagram::Messenger::MessageText drops a first-time contact's DM
# whenever the Graph profile fetch fails (missing Advanced Access, error 230,
# 9010, auth errors) — the contact is never created and create_message bails
# on the missing contact_inbox. Umi::InstagramFallbackContact creates the
# contact from the Instagram-scoped id with a placeholder name instead, so the
# message is never lost. (chatwoot#11578)
#
# remove-when: upstream creates a fallback contact (or otherwise persists the
# message) when the Instagram profile fetch fails in
# Instagram::Messenger::MessageText#ensure_contact.

Rails.application.reloader.to_prepare do
  unless Instagram::Messenger::MessageText.private_method_defined?(:ensure_contact)
    raise 'UMI zz_umi_ig_fallback_contact: Instagram::Messenger::MessageText#ensure_contact no longer exists — rebase the patch.'
  end

  unless Instagram::Messenger::MessageText.include?(Umi::InstagramFallbackContact)
    Instagram::Messenger::MessageText.prepend(Umi::InstagramFallbackContact)
  end
end
