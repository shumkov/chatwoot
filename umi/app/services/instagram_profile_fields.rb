# frozen_string_literal: true

# Names the Instagram profile fields Chatwoot wants instead of trusting Meta's
# defaults.
#
# On the Facebook-page-linked path upstream calls get_object with no `fields`
# argument at all and relies on whatever Meta chooses to return. Today that
# happens to include follower count, verified badge and the follow
# relationship — the four fields the sidebar now shows. It is not contractual:
# if Meta trims its default set those four vanish with no error and no log
# line, and the only symptom would be new contacts quietly arriving without
# numbers. The sibling Instagram-Login path (Instagram::MessageText) already
# names its fields explicitly; this brings the two into line.
#
# The method is reimplemented rather than wrapped because the field list has to
# reach get_object, and there is no seam for it in the upstream body. The two
# error handlers below are upstream's own; the boot guard fails loud if either
# is renamed.
module Umi::InstagramProfileFields
  FIELDS = %w[name username profile_pic follower_count is_user_follow_business is_business_follow_user is_verified_user].freeze

  private

  def fetch_instagram_user(ig_scope_id)
    k = Koala::Facebook::API.new(@inbox.channel.page_access_token) if @inbox.facebook?
    # A fresh options hash per call: Koala mutates the hash it is given, so a
    # shared constant raises FrozenError on the first request.
    k.get_object(ig_scope_id, { fields: FIELDS.join(',') }) || {}
  rescue Koala::Facebook::AuthenticationError => e
    handle_authentication_error(e)
    {}
  rescue StandardError, Koala::Facebook::ClientError => e
    handle_client_error(e)
    {}
  end
end
