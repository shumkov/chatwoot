# frozen_string_literal: true

# UMI patch: a private note created from an interactive sign-in session records its sender in
# content_attributes['umi_signed_in_sender_id']; no client value or other create path can set it, and an update can
# only remove it (writes that skip callbacks are not guarded). Rationale:
# umi/app/models/signed_in_note_provenance.rb and umi/app/controllers/conversations/signed_in_note_provenance.rb.
#
# Fail loud if upstream moves anything this relies on: a silently missing check or hook would either let a forged value
# through or stop marking notes.
Rails.application.config.to_prepare do
  controller = Api::V1::Accounts::Conversations::MessagesController
  raise 'UMI signed-in note provenance: native message creation changed' unless controller.method_defined?(:create)
  raise 'UMI signed-in note provenance: token authentication check changed' unless controller.private_method_defined?(:authenticate_by_access_token?)
  raise 'UMI signed-in note provenance: interactive session tracking changed' unless User.reflect_on_association(:user_sessions)
  unless DeviseOverrides::SessionsController.private_method_defined?(:track_user_session)
    raise 'UMI signed-in note provenance: sign-in session tracking changed'
  end
  unless DeviseTokenAuth::Concerns::SetUserByToken.protected_method_defined?(:set_user_by_token)
    raise 'UMI signed-in note provenance: devise token validation changed'
  end
  raise 'UMI signed-in note provenance: message attributes store changed' unless Message.stored_attributes.key?(:content_attributes)

  Message.include(Umi::SignedInNoteProvenance) unless Message.include?(Umi::SignedInNoteProvenance)
  controller.include(Umi::Conversations::SignedInNoteProvenance) unless controller.include?(Umi::Conversations::SignedInNoteProvenance)
end
