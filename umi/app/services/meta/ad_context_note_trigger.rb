# frozen_string_literal: true

# Hooks the ad-context note onto Meta ad attribution (patch 20).
#
# Prepended onto Umi::FbigAdAttribution rather than written into it. Patch 20
# goes away when upstream captures Meta referrals itself, and an enqueue living
# inside that file would disappear with it — taking the erasure hook below with
# it, silently. Prepending means the initializer's guard raises at boot instead.
module Umi::Meta::AdContextNoteTrigger
  # `super` stays outside the rescue. Patch 20's promote takes a row lock and
  # can raise; letting this rescue swallow that would relabel an attribution
  # failure as an enqueue failure and skip its exception-tracker call, on an
  # installation where the log line is the only signal there is.
  def promote(message, referral)
    super
    return unless from_ads?(referral)

    conversation = message.conversation
    return if conversation.reload.custom_attributes['meta_ad_id'].blank?

    begin
      Umi::Meta::AdContextNoteJob.perform_later(conversation.id)
    rescue StandardError => e
      Rails.logger.warn("[UMI-FBIG] stage=ad_context_enqueue_failed conversation=#{conversation.id} error=#{e.class}")
    end
  end

  # Erasure counterpart. Patch 20 strips ad attribution on a Shopify redaction
  # because which ad someone clicked is behavioural data about them; the note
  # carries the same fact plus the ad's copy, so it has to go with it.
  #
  # The whole row is deleted rather than a field stripped: unlike the referral
  # object, the sensitive text is the message body itself.
  #
  # Selected in Ruby, deleted by id. messages.content_attributes is a json
  # column with a `store` coder, so its stored value is a JSON string and a
  # `content_attributes::jsonb -> 'key'` predicate silently matches nothing.
  def purge_for(contact)
    super

    conversation_ids = contact.conversations.pluck(:id)
    return if conversation_ids.empty?

    ids = Message.where(conversation_id: conversation_ids)
                 .select { |message| message.content_attributes[Umi::Meta::AdContextNoteJob::MARKER].present? }
                 .map(&:id)
    Message.where(id: ids).delete_all if ids.any?
  end
end
