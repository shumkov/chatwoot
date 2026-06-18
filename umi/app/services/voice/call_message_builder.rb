# frozen_string_literal: true

# Creates the voice_call message that represents a call in the conversation timeline
# (the Chatwoot "call log" / screen-pop). Realtime updates ride message.touch.
class Umi::Voice::CallMessageBuilder
  def initialize(call:)
    @call = call
  end

  def perform!
    return @call.message if @call.message

    @call.conversation.messages.create!(
      account_id: @call.account_id,
      inbox_id: @call.inbox_id,
      message_type: @call.outgoing? ? :outgoing : :incoming,
      content_type: :voice_call,
      sender: @call.outgoing? ? @call.accepted_by_agent : @call.contact,
      content_attributes: { data: data }
    )
  end

  private

  def data
    {
      call_id: @call.id,
      call_sid: @call.provider_call_id,
      call_source: @call.provider,
      call_direction: @call.direction,
      status: @call.display_status
    }
  end
end
