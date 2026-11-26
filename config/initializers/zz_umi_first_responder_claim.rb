# frozen_string_literal: true

# UMI patch: the first reply from an interactive sign-in session claims an
# unassigned conversation. Off unless InstallationConfig
# UMI_FIRST_RESPONDER_CLAIM lists inbox ids. Rationale and provenance proof:
# umi/app/controllers/conversations/first_responder_claim.rb and
# docs/UMI-FIRST-RESPONDER-CLAIM-SPEC.md.
#
# Fail loud if upstream moves anything the provenance check relies on: a
# silently missing check could let an access-token reply claim, and a missing
# hook would silently stop claims.
Rails.application.config.to_prepare do
  controller = Api::V1::Accounts::Conversations::MessagesController
  raise 'UMI first responder claim: native message creation changed' unless controller.method_defined?(:create)
  raise 'UMI first responder claim: token authentication check changed' unless controller.private_method_defined?(:authenticate_by_access_token?)
  raise 'UMI first responder claim: native human response check changed' unless Message.private_method_defined?(:human_response?)
  raise 'UMI first responder claim: interactive session tracking changed' unless User.reflect_on_association(:user_sessions)
  unless DeviseOverrides::SessionsController.private_method_defined?(:track_user_session)
    raise 'UMI first responder claim: sign-in session tracking changed'
  end
  unless DeviseTokenAuth::Concerns::SetUserByToken.protected_method_defined?(:set_user_by_token)
    raise 'UMI first responder claim: devise token validation changed'
  end

  controller.include(Umi::Conversations::FirstResponderClaim) unless controller.include?(Umi::Conversations::FirstResponderClaim)
end
