# frozen_string_literal: true

# Resolves, for an inbound Twilio voice webhook, the caller number, the matched Chatwoot
# contact name, and the agent SIP usernames to ring.
class Umi::Voice::InboundResolver
  def initialize(channel:, params:)
    @channel = channel
    @params = params
  end

  def caller_number
    @params[:From].to_s.delete_prefix('client:').delete_prefix('whatsapp:')
  end

  def caller_name
    @channel.account.contacts.find_by(phone_number: caller_number)&.name
  end

  # P0: ring the agents assigned to the voice inbox, mapped to their SIP usernames.
  # (Online-only filtering comes in P1.)
  def agent_usernames
    inbox = @channel.inbox
    return [] if inbox.blank?

    inbox.inbox_members.limit(Umi::Voice::Twiml::DialBuilder::MAX_TARGETS).pluck(:user_id).map { |id| "agent-#{id}" }
  end
end
