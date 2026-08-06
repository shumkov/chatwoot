# frozen_string_literal: true

# UMI patch: name new Instagram contacts from their handle when Meta returns
# no display name.
#
# Meta's profile fetch now succeeds for most Instagram senders but omits
# `name`, so upstream mints a Haikunator name ("lingering-sun-586") that no
# repair pass can distinguish from an agent's own wording. The handle is in
# the same response.
#
# Prepended on the base class so both the Facebook-page-linked and
# Instagram-Login paths are covered; patch #10 prepends a different method on
# a subclass, so there is no ordering conflict between them.
#
# remove-when: upstream falls back to `username` when Meta returns no `name`
# in Instagram::WebhooksBaseService#find_or_create_contact, or Meta starts
# returning display names for Instagram users.

Rails.application.reloader.to_prepare do
  unless Instagram::WebhooksBaseService.private_method_defined?(:find_or_create_contact)
    raise 'UMI zz_umi_ig_handle_name: Instagram::WebhooksBaseService#find_or_create_contact no longer exists — rebase the patch.'
  end

  Instagram::WebhooksBaseService.prepend(Umi::InstagramHandleName) unless Instagram::WebhooksBaseService.include?(Umi::InstagramHandleName)
end
