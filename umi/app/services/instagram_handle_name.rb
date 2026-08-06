# frozen_string_literal: true

# Name a new Instagram contact from their handle when Meta declines to give a
# display name.
#
# With Business Asset User Profile Access granted, the profile fetch succeeds
# for most Instagram senders but returns only `username` (plus sometimes
# `profile_pic`) — no `name`. Upstream passes that nil straight to
# ContactInboxWithContactBuilder#contact_name, which falls back to
# Haikunator and mints a contact called e.g. "lingering-sun-586".
#
# That is worse than the placeholder it replaced. A random adjective-noun name
# is indistinguishable from one an agent typed, so no later repair pass can
# safely rewrite it — the contact is stuck with it permanently.
#
# This is a different failure than patch #10 covers: there the profile fetch
# RAISES and no contact is created at all. Here it succeeds, the contact
# inbox exists, and patch #10's fallback is never reached.
module Umi::InstagramHandleName
  private

  def find_or_create_contact(user)
    handle = user['username']
    return super if user['name'].present? || handle.blank?

    super(user.merge('name' => handle))

    # Only claim names this actually wrote. An already-existing contact takes
    # super's early-return path and keeps whatever name it had — stamping that
    # would licence a later pass to overwrite an agent's edit.
    return if @contact.blank? || @contact.name != handle

    record_written_name(handle)
  end

  # Enrichment refreshes a name only while it still equals what we wrote, so
  # without this the handle is frozen and could never be upgraded to a real
  # display name if Meta starts returning one. An agent's edit breaks the
  # equality and ends the claim.
  def record_written_name(handle)
    @contact.update!(additional_attributes: @contact.additional_attributes.merge('umi_profile_name' => handle))
  end
end
