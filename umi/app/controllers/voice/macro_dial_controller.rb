# frozen_string_literal: true

# Endpoint the "Call contact" macro's send_webhook_event action posts to. The macro runs
# server-side when an agent taps it (works in the native mobile app, which can't *open* link
# attributes), and the webhook payload carries the conversation — so Chatwoot rings the assignee's
# SIP softphone and bridges to the contact (logged, business number). No mobile-app fork.
class Umi::Voice::MacroDialController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def create
    return head :forbidden unless Umi::Voice.valid_macro_token?(params[:token])

    conversation = find_conversation
    return head :not_found if conversation.nil?

    channel = conversation.inbox.channel
    return head :unprocessable_entity unless callable?(conversation, channel)

    Umi::Voice::OutboundCallBuilder.perform!(
      account: conversation.account, channel: channel, user: conversation.assignee,
      contact: conversation.contact, conversation: conversation
    )
    head :ok
  end

  private

  def find_conversation
    account = Account.find_by(id: params.dig(:account, :id))
    account&.conversations&.find_by(display_id: params[:id])
  end

  def callable?(conversation, channel)
    conversation.assignee.present? && conversation.contact.present? &&
      channel.is_a?(::Channel::TwilioSms) && channel.umi_voice_enabled?
  end
end
