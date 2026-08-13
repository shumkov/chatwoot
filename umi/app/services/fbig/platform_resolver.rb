# frozen_string_literal: true

# Decides whether a Meta contact_inbox is a Messenger or an Instagram identity.
#
# One Facebook Page channel carries both platforms, and almost every enrichment
# decision downstream turns on which one this is: Instagram profiles carry a
# handle and no display name, Messenger profiles the reverse.
#
# The conversation marker is authoritative — the Instagram builder sets it and
# outbound routing depends on it, so it is reliable on live and imported rows
# alike. Preferred by contact_inbox, since a contact can own one per platform;
# legacy rows without that link fall back to the inbox pairing.
class Umi::Fbig::PlatformResolver
  # With no conversations at all, Meta's own answer discriminates: an Instagram
  # profile carries `username`, a Messenger one `first_name`.
  def self.for(contact_inbox, profile)
    # compact: Facebook conversations carry no 'type' key, so pluck yields
    # [nil] rather than []. Without this the legacy fallback never runs and the
    # messenger branch is unreachable, since [nil].any? is false.
    types = conversation_types(contact_inbox.id, nil).compact
    types = conversation_types(nil, contact_inbox).compact if types.empty?
    return :instagram if types.include?('instagram_direct_message')
    return :messenger if types.any?

    profile['username'].present? || contact_inbox.contact.additional_attributes['social_instagram_user_name'].present? ? :instagram : :messenger
  end

  def self.conversation_types(contact_inbox_id, contact_inbox)
    scope = if contact_inbox
              Conversation.where(contact_id: contact_inbox.contact_id, inbox_id: contact_inbox.inbox_id)
            else
              Conversation.where(contact_inbox_id: contact_inbox_id)
            end
    scope.distinct.pluck(Arel.sql("additional_attributes->>'type'"))
  end
  private_class_method :conversation_types
end
