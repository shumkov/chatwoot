# frozen_string_literal: true

# Copies the Instagram profile facts Meta just handed us into the bucket the
# product actually reads, at the moment the customer messages.
#
# Upstream stores follower count, verified badge and the follow relationship in
# contacts.additional_attributes, which no sidebar, filter or automation rule
# consults. Without this, a new influencer's numbers would sit invisible until
# the nightly refresher happened to rotate around to them, which for a
# population this size is weeks — long after the conversation is over.
module Umi::InstagramProfileProjection
  private

  def update_instagram_profile_link(user)
    super

    # super is the only writer of these values, and patch #18's copy of this
    # method declines to call it for an erased contact — so a contact with
    # nothing stored simply projects nothing.
    Umi::Meta::InstagramProfileAttributes.project!(@contact) if @contact
  end
end
