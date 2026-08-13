# frozen_string_literal: true

# UMI patch: make the Instagram profile facts Meta already gives us visible,
# filterable and usable in automation.
#
# Meta returns follower count, verified badge and the follow relationship on
# every Instagram profile fetch Chatwoot makes, and upstream files them in
# contacts.additional_attributes — which the sidebar, the filters, the
# automation rules and the AI assistant all ignore. This projects them into
# custom_attributes, where a definition row makes them mean something.
#
# App code:
#   umi/app/services/meta/instagram_profile_attributes.rb  (definitions + projection)
#   umi/app/services/instagram_profile_projection.rb       (live path)
#   umi/app/services/instagram_profile_fields.rb           (explicit field list)
#
# remove-when: upstream surfaces the Instagram profile fields it already
# stores — a contact sidebar section, a filter, or first-class custom
# attributes — so the projection is redundant.

Rails.application.reloader.to_prepare do
  unless Instagram::WebhooksBaseService.private_method_defined?(:update_instagram_profile_link)
    raise 'UMI zz_umi_ig_profile_attributes: Instagram::WebhooksBaseService#update_instagram_profile_link no longer exists — rebase the patch.'
  end

  # Both private error handlers are called by the reimplemented fetch below.
  %i[fetch_instagram_user handle_authentication_error handle_client_error].each do |method|
    next if Instagram::Messenger::MessageText.private_method_defined?(method)

    raise "UMI zz_umi_ig_profile_attributes: Instagram::Messenger::MessageText##{method} no longer exists — rebase the patch."
  end

  unless Instagram::WebhooksBaseService.include?(Umi::InstagramProfileProjection)
    Instagram::WebhooksBaseService.prepend(Umi::InstagramProfileProjection)
  end

  unless Instagram::Messenger::MessageText.include?(Umi::InstagramProfileFields)
    Instagram::Messenger::MessageText.prepend(Umi::InstagramProfileFields)
  end
end
