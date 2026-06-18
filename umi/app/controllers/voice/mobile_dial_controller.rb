# frozen_string_literal: true

require 'cgi'

# Tap-to-call from anywhere a link renders (e.g. a contact custom attribute shown in the native
# mobile app). A signed token identifies the contact; Chatwoot places the call — ringing the
# conversation assignee's SIP softphone, then bridging to the contact — so it is logged and uses
# the business number, with no mobile-app fork. GET shows a confirm page; POST places the call
# (so link prefetching can't trigger calls).
class Umi::Voice::MobileDialController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  before_action :load_contact

  def show
    return render_page('This call link is invalid.', status: :forbidden) if @contact.nil?
    return render_page("Open a conversation with #{@contact.name} in a voice inbox first.") if conversation.nil?

    render_page("Call #{@contact.name}?", call_button: true)
  end

  def create
    return render_page('This call link is invalid.', status: :forbidden) if @contact.nil?
    return render_page("No voice-enabled conversation for #{@contact.name}.") if conversation.nil?
    return render_page('Assign this conversation to an agent first, then tap Call.') if conversation.assignee.nil?

    Umi::Voice::OutboundCallBuilder.perform!(
      account: conversation.account, channel: conversation.inbox.channel,
      user: conversation.assignee, contact: @contact, conversation: conversation
    )
    render_page("Calling #{@contact.name}… your phone will ring — answer to connect.")
  end

  private

  def load_contact
    contact_id = Umi::Voice.verify_dial_token(params[:token])
    @contact = contact_id && ::Contact.find_by(id: contact_id)
  end

  def conversation
    return @conversation if defined?(@conversation)

    @conversation = @contact&.conversations
                            &.where(status: %i[open pending])&.order(last_activity_at: :desc)
                            &.detect { |convo| voice_inbox?(convo.inbox) }
  end

  def voice_inbox?(inbox)
    inbox.channel.is_a?(::Channel::TwilioSms) && inbox.channel.umi_voice_enabled?
  end

  def render_page(message, status: :ok, call_button: false)
    html = <<~HTML
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1"><title>Call</title></head>
      <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;text-align:center;padding:3rem 1.5rem;color:#1f2937;">
      <p style="font-size:1.25rem;margin-bottom:1.5rem;">#{CGI.escapeHTML(message)}</p>
      #{call_button ? call_button_html : ''}
      </body></html>
    HTML
    render html: html.html_safe, layout: false, status: status # rubocop:disable Rails/OutputSafety
  end

  def call_button_html
    action = CGI.escapeHTML("/umi/voice/dial/#{params[:token]}")
    <<~HTML
      <form method="post" action="#{action}">
      <button type="submit" style="font-size:1.1rem;padding:0.9rem 2.2rem;border:0;border-radius:9999px;background:#16a34a;color:#fff;">📞 Call now</button>
      </form>
    HTML
  end
end
