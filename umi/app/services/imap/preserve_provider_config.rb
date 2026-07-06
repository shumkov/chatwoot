# frozen_string_literal: true

# Preserve extra provider_config keys (e.g. imap_folder — see Umi::Imap::ConfigurableFolder)
# across an OAuth token refresh. Stock BaseRefreshOauthTokenService#update_channel_provider_config
# REPLACES provider_config with only the token keys, so on the first refresh (Google access tokens
# last ~1h) it would drop imap_folder both in-memory and in the DB, silently reverting the inbox to
# reading the whole INBOX. Merge the refreshed tokens into the existing config instead.
module Umi::Imap::PreserveProviderConfig
  def update_channel_provider_config(new_tokens)
    channel.provider_config = (channel.provider_config || {}).merge(
      'access_token' => new_tokens[:access_token],
      'refresh_token' => new_tokens[:refresh_token],
      'expires_on' => Time.at(new_tokens[:expires_at]).utc.to_s
    )
    channel.save!
  end
end
