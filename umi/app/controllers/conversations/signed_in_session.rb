# frozen_string_literal: true

# A request comes from an interactive sign-in session when it is not token-authenticated and the devise client
# validated for it belongs to one of the user's session rows. Only an interactive password, SSO or MFA sign-in creates
# such a row (a Platform API login link is an SSO sign-in); impersonation and other server-minted tokens have none. An
# agent account can also own the automation's access tokens, so the sender alone proves nothing. This proves an
# authenticated session of that user, not who is at the keyboard.
module Umi::Conversations::SignedInSession
  private

  # The user and devise client behind this request, or nil for an access-token request. Reads no session row. Call it
  # before the action: devise clears the client on the token object once the response headers are written.
  def signed_in_session_candidate
    return if authenticate_by_access_token? || !Current.user.is_a?(User) || @token&.client.blank?

    [Current.user, @token.client]
  end

  def signed_in_session?(user, client)
    user.user_sessions.exists?(client_id: client)
  end
end
