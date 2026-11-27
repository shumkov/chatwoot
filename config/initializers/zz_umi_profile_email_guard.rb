# frozen_string_literal: true

# UMI patch: an access-token profile request cannot change the login email. Rationale:
# umi/app/controllers/profile_email_guard.rb.
#
# Fail loud if upstream moves anything this relies on: a silently missing guard would let a token change the email
# again, and a changed normalisation would refuse requests that keep the current email.
Rails.application.config.to_prepare do
  controller = Api::V1::ProfilesController
  raise 'UMI profile email guard: native profile update changed' unless controller.method_defined?(:update)
  raise 'UMI profile email guard: token authentication check changed' unless controller.private_method_defined?(:authenticate_by_access_token?)
  raise 'UMI profile email guard: native profile parameters changed' unless controller.private_method_defined?(:profile_params)
  unless Devise.case_insensitive_keys.include?(:email) && Devise.strip_whitespace_keys.include?(:email)
    raise 'UMI profile email guard: native email normalisation changed'
  end

  controller.prepend(Umi::ProfileEmailGuard) unless controller.ancestors.include?(Umi::ProfileEmailGuard)
end
