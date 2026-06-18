# frozen_string_literal: true

# Click-to-call endpoint (POST /api/v1/accounts/:account_id/contacts/:contact_id/call).
# Overrides the premium-gated enterprise endpoint via routes.prepend in zz_umi_voice.rb.
class Umi::Voice::ContactCallsController < Api::V1::Accounts::BaseController
  def create
    contact = Current.account.contacts.find(params[:contact_id])
    authorize contact, :show?
    inbox = voice_inbox
    call = Umi::Voice::OutboundCallBuilder.perform!(
      account: Current.account, channel: inbox.channel, user: Current.user,
      contact: contact, conversation: conversation(inbox, contact)
    )
    render json: { call_sid: call.provider_call_id, conversation_id: call.conversation.display_id }
  end

  private

  # Scope to inboxes the agent is actually assigned to (admins get all via assigned_inboxes),
  # and require voice to be enabled — mirrors the enterprise authz.
  def voice_inbox
    inbox = Current.user.assigned_inboxes.find(params.require(:inbox_id))
    raise ActiveRecord::RecordNotFound, 'Voice not enabled on this inbox' unless inbox.channel.umi_voice_enabled?

    authorize inbox, :show?
    inbox
  end

  # Only reuse a conversation that genuinely belongs to this inbox + contact.
  def conversation(inbox, contact)
    return if params[:conversation_id].blank?

    Current.account.conversations.find_by(display_id: params[:conversation_id], inbox_id: inbox.id, contact_id: contact.id)
  end
end
