# frozen_string_literal: true

# For a first-time Instagram contact (FB-page-linked channel), stock
# Instagram::Messenger::MessageText only creates the contact when the Graph
# profile fetch succeeds; on failure (no Advanced Access to
# instagram_manage_messages, error 230 user-consent, 9010 no-matching-user,
# expired token) the contact is never created and create_message silently
# drops the inbound DM. Meta delivers webhooks once, so the DM is lost.
#
# The message is the valuable artifact: when the profile fetch yields nothing,
# create the contact anyway from the Instagram-scoped sender id with a
# placeholder name so the DM persists. The placeholder name is permanent until
# an agent renames the contact — the profile is only fetched for a contact's
# first message, so a later successful fetch never runs for these contacts.
# Also applies to echo events (agent DMs a brand-new user from the native
# app): the thread is logged with a placeholder contact instead of vanishing.
#
# UMI_IG_FALLBACK_CONTACT=off restores stock behaviour (drop the DM) without
# a redeploy — only a container restart to pick up the env.
module Umi::InstagramFallbackContact
  private

  def ensure_contact(ig_scope_id)
    super
    return if @contact_inbox.present?
    return if ENV['UMI_IG_FALLBACK_CONTACT'] == 'off'

    Rails.logger.warn(
      "[UMI-FBIG] stage=fallback_contact channel=instagram_messenger inbox_id=#{@inbox.id} " \
      "ig_scope_id=#{ig_scope_id} reason=profile_fetch_failed"
    )
    @contact_inbox = @inbox.channel.create_contact_inbox(ig_scope_id, fallback_contact_name(ig_scope_id))
    @contact = @contact_inbox&.contact
  end

  def fallback_contact_name(ig_scope_id)
    "Instagram user #{ig_scope_id.to_s.last(4)}"
  end
end
