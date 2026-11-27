# frozen_string_literal: true

# UMI patch: the login email decides who can recover the account, so a profile request authenticated with an access
# token cannot change it; changing it needs an interactive sign-in session. Every other supported profile field still
# updates with a token, and an email equal to the current one as Devise normalises it (stripped, lower case) is not a
# change.
#
# The refusal happens before the native action runs, so nothing else in the same request is applied either.
module Umi::ProfileEmailGuard
  def update
    return super unless authenticate_by_access_token? && token_email_change?

    render json: { error: 'email_change_requires_signed_in_session' }, status: :forbidden
  end

  private

  def token_email_change?
    profile = params[:profile]
    profile.respond_to?(:key?) && profile.key?(:email) && profile[:email].to_s.strip.downcase != current_user.email
  end
end
