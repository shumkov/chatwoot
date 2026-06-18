# frozen_string_literal: true

# On an inbound Twilio voice webhook, idempotently materialise the contact, conversation,
# Call row and voice_call message so the conversation screen-pops in Chatwoot.
class Umi::Voice::InboundCallBuilder
  def self.perform!(**)
    new(**).perform!
  end

  def initialize(channel:, from_number:, call_sid:, provider: :twilio)
    @channel = channel
    @from_number = from_number
    @call_sid = call_sid
    @provider = provider
  end

  def perform!
    existing = Umi::Call.find_by(provider: @provider, provider_call_id: @call_sid)
    return existing if existing

    ActiveRecord::Base.transaction do
      contact_inbox = build_contact_inbox
      conversation = find_or_create_conversation(contact_inbox)
      call = create_call(contact_inbox.contact, conversation)
      call.update!(message: Umi::Voice::CallMessageBuilder.new(call: call).perform!)
      call
    end
  rescue ActiveRecord::RecordNotUnique
    # Twilio retried the webhook concurrently — return the row the other thread created.
    Umi::Call.find_by(provider: @provider, provider_call_id: @call_sid)
  end

  private

  def inbox
    @channel.inbox
  end

  def build_contact_inbox
    ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: @from_number,
      contact_attributes: { phone_number: @from_number, name: @from_number }
    ).perform
  end

  def find_or_create_conversation(contact_inbox)
    open = contact_inbox.conversations.where(status: %i[open pending]).order(:created_at).last
    return open if open

    inbox.account.conversations.create!(
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      status: :open
    )
  end

  def create_call(contact, conversation)
    Umi::Call.create!(
      account: inbox.account, inbox: inbox, conversation: conversation, contact: contact,
      provider: @provider, direction: :incoming, status: 'ringing', provider_call_id: @call_sid,
      meta: { 'initiated_at' => Time.zone.now.to_i }
    )
  end
end
