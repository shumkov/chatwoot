# frozen_string_literal: true

# When the /PSID profile fetch yields nothing (Meta denies it with error
# 100/33 for apps without Business Asset User Profile Access and for
# pre-app-connection threads), upstream permanently names the contact
# "John Doe". The real name is still available via the Conversations API's
# participants field — use it before accepting the placeholder. Applies to
# both inbound senders and echo recipients (@sender_id is the customer's PSID
# in both modes).
module Umi::FacebookContactNameFallback
  private

  def process_contact_params_result(result)
    if result['first_name'].blank? && result['last_name'].blank?
      fallback_name = Umi::Fbig::ParticipantNameService.new(@inbox.channel).name_for(@sender_id)
      if fallback_name
        Rails.logger.info("[UMI-FBIG] stage=participant_name_used psid=#{@sender_id}")
        return { name: fallback_name, account_id: @inbox.account_id, avatar_url: result['profile_pic'] }
      end
    end
    super
  end
end
