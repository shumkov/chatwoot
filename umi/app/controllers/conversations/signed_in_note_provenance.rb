# frozen_string_literal: true

# UMI patch: a private note created from an interactive sign-in session records its sender as signed in
# (Umi::SignedInNoteProvenance), so Shumabit can tell staff direction from notes the automation writes with the same
# account's access token. The session check is the first-responder claim's (Umi::Conversations::SignedInSession).
#
# The sender is held only while the native action runs and is cleared when it ends, whether the action succeeds,
# fails or raises.
module Umi::Conversations::SignedInNoteProvenance
  extend ActiveSupport::Concern
  include Umi::Conversations::SignedInSession

  included do
    around_action :record_signed_in_note_sender, only: :create # rubocop:disable Rails/LexicallyScopedActionFilter
  end

  private

  def record_signed_in_note_sender(&)
    user, client = signed_in_session_candidate if ActiveModel::Type::Boolean.new.cast(params[:private])
    return yield unless user && signed_in_session?(user, client)

    Umi::SignedInNoteProvenance.signed_in_sender(user.id, &)
  end
end
