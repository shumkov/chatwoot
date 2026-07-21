# frozen_string_literal: true

# Click-to-call: rings the initiating agent's SIP softphone via Twilio, then bridges to the
# contact (the agent's outbound_twiml dials the contact on answer). Logs the call in Chatwoot.
class Umi::Voice::OutboundCallBuilder
  def self.perform!(**)
    new(**).perform!
  end

  def initialize(account:, channel:, user:, contact:, conversation: nil)
    @account = account
    @channel = channel
    @user = user
    @contact = contact
    @conversation = conversation
  end

  def perform!
    conversation = @conversation || find_or_create_conversation
    # Originate outside the DB transaction so a slow Twilio call can't exhaust the pool.
    twilio_call = originate!

    ActiveRecord::Base.transaction do
      call = Umi::Call.create!(
        account: @account, inbox: inbox, conversation: conversation, contact: @contact,
        provider: :twilio, direction: :outgoing, status: 'ringing',
        provider_call_id: twilio_call.sid, accepted_by_agent: @user,
        meta: { 'initiated_at' => Time.zone.now.to_i }
      )
      call.update!(message: Umi::Voice::CallMessageBuilder.new(call: call).perform!)
      call
    end
  end

  private

  def inbox
    @channel.inbox
  end

  def originate!
    @channel.umi_voice_client.calls.create(
      to: "sip:agent-#{@user.id}@#{@channel.umi_sip_domain}",
      from: @channel.phone_number,
      url: outbound_twiml_url,
      # REST-originated calls only send status webhooks when asked on create (the
      # number-level callback covers incoming calls only).
      status_callback: "#{Umi::Voice.public_base}/umi/voice/#{phone_digits}/status",
      status_callback_event: %w[initiated ringing answered completed],
      status_callback_method: 'POST'
    )
  end

  def outbound_twiml_url
    "#{Umi::Voice.public_base}/umi/voice/#{phone_digits}/outbound_twiml?to=#{CGI.escape(@contact.phone_number.to_s)}"
  end

  def phone_digits
    @channel.phone_number.to_s.gsub(/\D/, '')
  end

  def find_or_create_conversation
    contact_inbox = inbox.contact_inboxes.find_by(contact_id: @contact.id) ||
                    ContactInboxWithContactBuilder.new(inbox: inbox, source_id: @contact.phone_number,
                                                       contact_attributes: { phone_number: @contact.phone_number }).perform
    contact_inbox.conversations.where(status: %i[open pending]).order(:created_at).last ||
      @account.conversations.create!(contact_inbox_id: contact_inbox.id, inbox_id: inbox.id,
                                     contact_id: @contact.id, status: :open)
  end
end
