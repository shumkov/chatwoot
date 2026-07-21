# frozen_string_literal: true

require 'erb'

# Builds the TwiML that rings the on-duty agents' SIP softphones for an inbound call,
# injecting the Chatwoot contact name into the Remote-Party-ID header.
class Umi::Voice::Twiml::DialBuilder
  MAX_TARGETS = 10

  def initialize(domain:, agent_usernames:, caller_number:, caller_name:, dial_action_url:, # rubocop:disable Metrics/ParameterLists
                 recording_status_url: nil, sip_status_url: nil, timeout: 25)
    @domain = domain
    @agent_usernames = Array(agent_usernames).first(MAX_TARGETS)
    @caller_number = caller_number
    @caller_name = caller_name
    @dial_action_url = dial_action_url
    @recording_status_url = recording_status_url
    @sip_status_url = sip_status_url
    @timeout = timeout
  end

  def to_xml
    response = ::Twilio::TwiML::VoiceResponse.new
    response.dial(**dial_options) do |dial|
      @agent_usernames.each { |username| dial.sip(sip_uri(username), **sip_options(username)) }
    end
    response.to_s
  end

  private

  def dial_options
    opts = { caller_id: @caller_number, timeout: @timeout, action: @dial_action_url, answer_on_bridge: true }
    return opts if @recording_status_url.blank?

    opts.merge(record: 'record-from-answer-dual', recording_status_callback: @recording_status_url, recording_status_callback_event: 'completed')
  end

  # An answered callback per <Sip> leg, tagged with the agent username, is the only way to
  # learn WHICH agent won a first-answer-wins group ring (the <Dial action> result carries
  # no per-leg identity).
  def sip_options(username)
    return {} if @sip_status_url.blank?

    { status_callback: "#{@sip_status_url}?agent=#{username}", status_callback_event: 'answered' }
  end

  # Dial the GLOBAL SIP domain (…sip.twilio.com), never an edge URI — Twilio rejects edge
  # URIs for registered endpoints with error 32220.
  def sip_uri(username)
    uri = "sip:#{username}@#{@domain}"
    rpid = remote_party_id
    rpid.present? ? "#{uri}?Remote-Party-ID=#{ERB::Util.url_encode(rpid)}" : uri
  end

  # Groundwire shows this name when its "Incoming Caller ID" priority lists Remote-Party-ID first.
  def remote_party_id
    return if @caller_name.blank?

    %("#{@caller_name}" <sip:#{@caller_number}@#{@domain}>)
  end
end
