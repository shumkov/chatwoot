# frozen_string_literal: true

# Resolves a Messenger user's display name via the page-inbox Conversations
# API (`/{page_id}/conversations?user_id=<psid>&fields=participants`) — the
# data path Meta Business Suite itself shows names from. It works with the
# permissions the app already holds (pages_messaging family), unlike the
# /PSID User Profile API, which Meta denies (error 100/33) for apps without
# the Business Asset User Profile Access feature and for pre-app-connection
# threads. Verified against production 2026-07-23: all twelve profile-locked
# senders resolved.
class Umi::Fbig::ParticipantNameService
  def initialize(channel)
    @channel = channel
  end

  # Returns the participant's name, or nil when the thread or name is
  # unavailable — callers keep their existing placeholder behaviour then.
  def name_for(psid)
    conversation = api.get_connections(@channel.page_id, 'conversations',
                                       { platform: 'messenger', user_id: psid, fields: 'participants' }).first
    participant = conversation&.dig('participants', 'data')&.find { |entry| entry['id'] == psid }
    participant && participant['name'].presence
  rescue StandardError => e
    Rails.logger.warn("[UMI-FBIG] stage=participant_name_failed psid=#{psid} error=#{e.class}: #{e.message}")
    nil
  end

  private

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
