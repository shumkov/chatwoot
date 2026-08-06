# frozen_string_literal: true

# Resolves a Messenger or Instagram user's display identity via the page-inbox
# Conversations API (`/{page_id}/conversations?user_id=<id>&fields=participants`)
# — the data path Meta Business Suite itself shows names from. It works with the
# permissions the app already holds (pages_messaging family), unlike the
# /PSID User Profile API, which Meta denies (error 100/33) for apps without
# the Business Asset User Profile Access feature and for pre-app-connection
# threads. Verified against production 2026-07-23: all twelve profile-locked
# senders resolved.
#
# The same path also answers for Instagram ids that the profile API refuses
# with error 230 ("user consent is required") — 12/12 in a production probe
# 2026-08-05, including 11 ids get_object rejected outright. Meta returns only
# `username` for Instagram participants, never a display name, so an Instagram
# lookup yields a handle.
class Umi::Fbig::ParticipantNameService
  # Meta exposes the display name on Messenger participants and only the
  # handle on Instagram ones.
  NAME_FIELD = { messenger: 'name', instagram: 'username' }.freeze

  def initialize(channel)
    @channel = channel
  end

  # Returns the participant's name (Messenger) or handle (Instagram), or nil
  # when the thread or name is unavailable — callers keep their existing
  # placeholder behaviour then. Platform defaults to messenger so the
  # Facebook caller's positional call keeps working unchanged.
  def name_for(id, platform: :messenger)
    conversation = api.get_connections(@channel.page_id, 'conversations',
                                       { platform: platform.to_s, user_id: id, fields: 'participants' }).first
    participant = conversation&.dig('participants', 'data')&.find { |entry| entry['id'] == id }
    # A successful call with no matching participant is indistinguishable from
    # "Meta has no name" unless it says so — both return nil.
    if participant.nil?
      Rails.logger.info("[UMI-FBIG] stage=participant_no_match platform=#{platform} id=#{id}")
      return nil
    end

    participant[NAME_FIELD.fetch(platform)].presence
  rescue Koala::Facebook::AuthenticationError
    # Callers abort the whole run on a dead token rather than repeating it once
    # per contact; swallowing it here would hide that.
    raise
  rescue StandardError => e
    Rails.logger.warn("[UMI-FBIG] stage=participant_name_failed platform=#{platform} id=#{id} error=#{e.class}: #{e.message}")
    nil
  end

  private

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
