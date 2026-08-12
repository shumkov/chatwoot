# frozen_string_literal: true

# Posts the ad-context private note on a conversation that carries Meta ad
# attribution.
#
# Runs in the background on purpose. The inbound message path must never wait on
# Meta: a slow or failing Graph call there would delay the customer's message,
# and a rescued database error inside the builder's transaction would kill it at
# COMMIT.
class Umi::Meta::AdContextNoteJob < ApplicationJob
  queue_as :medium

  # Flat five seconds rather than a growing backoff. The point of the note is to
  # reach the agent before they reply, and the fastest real agent reply measured
  # on ad taps is 26 seconds; a polynomial schedule would still be waiting.
  retry_on Umi::Meta::AdWelcomeMessageService::Unavailable, wait: 5.seconds, attempts: 4

  MARKER = 'umi_ad_context'

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil?

    ad_id = conversation.custom_attributes['meta_ad_id']
    return log(:skipped_no_ad_id, conversation_id) if ad_id.blank?
    return log(:skipped_present, conversation_id) if note?(conversation, status: 'ok')

    welcome = service(conversation).fetch(ad_id)
    write(conversation, body(conversation, welcome), ad_id, 'ok', guard: 'ok')
    log(:posted, conversation_id)
  rescue StandardError => e
    # Terminal handler for everything, not just Unavailable. Anything escaping
    # this job lands in the Sidekiq dead set, which nobody watches on this
    # installation — so an agent-visible note is the only signal that works.
    handle_failure(conversation, e)
  end

  private

  def service(conversation)
    token = conversation.inbox.channel.try(:page_access_token)
    # A Meta inbox with no token is a deployment fault, not a runtime condition.
    raise "no page_access_token on inbox #{conversation.inbox_id}" if token.blank?

    Umi::Meta::AdWelcomeMessageService.new(token)
  end

  def body(conversation, welcome)
    Umi::Meta::AdContextNotePresenter.new(welcome, tapped_title: tapped_title(conversation)).body
  end

  # The tap arrives as an ordinary incoming message whose text is the option
  # title. The first incoming message is the tap for an ad-originated thread.
  def tapped_title(conversation)
    conversation.messages.incoming.first&.content
  end

  # The check has to happen under the lock, not only before the Graph call: two
  # taps seconds apart, or a redelivered Meta webhook, put two of these jobs in
  # flight at once. Losing that race does not merely duplicate a note — if one
  # worker succeeds and the other is rate-limited, the agent gets a correct note
  # followed by one saying the ad could not be read.
  def write(conversation, body, ad_id, status, guard:)
    conversation.with_lock do
      # reload inside the lock: the association was already loaded by the
      # pre-flight check, and the other worker's insert happened after that.
      conversation.reload
      next if note?(conversation, status: guard)
      # Attribution may have been erased by a Shopify redaction while this job
      # was in flight; posting now would reinstate what erasure just removed.
      next if conversation.custom_attributes['meta_ad_id'].blank?

      # A failure note left by an earlier outage would otherwise sit above the
      # real one, telling the agent the ad is unreadable directly above its
      # contents.
      clear_failure_notes(conversation) if status == 'ok'

      conversation.messages.create!(
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        message_type: :outgoing,
        private: true,
        sender: nil,
        content: body,
        content_attributes: { MARKER => { 'ad_id' => ad_id, 'status' => status } }
      )
    end
  end

  # Read in Ruby, not SQL. messages.content_attributes is a json column carrying
  # a `store` coder, so the stored value is a JSON string and
  # `content_attributes::jsonb -> 'key'` matches nothing at all — silently.
  #
  # A nil status matches any note; 'ok' matches only a successful one, so a
  # failure note left by a transient Meta outage cannot block the real note
  # forever.
  def clear_failure_notes(conversation)
    stale = conversation.messages.select { |m| m.content_attributes.dig(MARKER, 'status') == 'error' }
    Message.where(id: stale.map(&:id)).delete_all if stale.any?
  end

  def note?(conversation, status:)
    conversation.messages.reload.any? do |message|
      marker = message.content_attributes[MARKER]
      marker.present? && (status.nil? || marker['status'] == status)
    end
  end

  def handle_failure(conversation, error)
    reason = error.is_a?(Umi::Meta::AdWelcomeMessageService::Unavailable) ? error.message : error.class.name
    Rails.logger.error("[UMI-FBIG] stage=ad_context_failed conversation=#{conversation&.id} reason=#{reason}")
    return if conversation.nil?

    write(conversation, Umi::Meta::AdContextNotePresenter.failure_body(reason),
          conversation.custom_attributes['meta_ad_id'], 'error', guard: nil)
  rescue StandardError => e
    # The note is the signal, so its own failure must not be what hides the
    # original one.
    Rails.logger.error("[UMI-FBIG] stage=ad_context_note_failed conversation=#{conversation&.id} error=#{e.class}")
  end

  def log(stage, conversation_id)
    Rails.logger.info("[UMI-FBIG] stage=ad_context_#{stage} conversation=#{conversation_id}")
  end
end
