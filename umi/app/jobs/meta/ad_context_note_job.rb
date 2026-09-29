# frozen_string_literal: true

# Meta lookups run outside the inbound transaction and row locks. The retained
# incoming source, rather than the mutable sidebar, owns each private note.
class Umi::Meta::AdContextNoteJob < ApplicationJob
  queue_as :medium

  MARKER = 'umi_ad_context'

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def perform(conversation_id, source_message_id = nil)
    @conversation = Conversation.find_by(id: conversation_id)
    return unless @conversation

    @source = if source_message_id
                @conversation.messages.find_by(id: source_message_id)
              else
                # Release compatibility for jobs queued before source IDs were included.
                Umi::FbigAdAttribution.latest_source(@conversation)
              end
    return unless @source && Umi::FbigAdAttribution.valid_source?(@source, @conversation)

    @contact = @conversation.contact
    return if @contact.additional_attributes['umi_profile_redacted']

    @binding = @conversation.attributes.slice('account_id', 'contact_id', 'inbox_id', 'contact_inbox_id')
    @referral = @source.content_attributes.fetch('referral').deep_dup
    @ad_id = @referral.fetch('ad_id').to_s
    @tapped_title = @source.content
    @source_time = @source.created_at
    return if note?(status: 'ok')

    welcome = service.fetch(@ad_id)
    body = Umi::Meta::AdContextNotePresenter.new(welcome, tapped_title: @tapped_title).body
    write(body, 'ok', guard: 'ok')
  rescue StandardError => e
    handle_failure(e)
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  private

  def service
    token = @conversation.inbox.channel.try(:page_access_token)
    raise "no page_access_token on inbox #{@conversation.inbox_id}" if token.blank?

    Umi::Meta::AdWelcomeMessageService.new(token)
  end

  def write(body, status, guard:) # rubocop:disable Metrics/CyclomaticComplexity
    @contact.with_lock do
      next if @contact.additional_attributes['umi_profile_redacted']

      @conversation.with_lock do
        next unless @conversation.attributes.slice(*@binding.keys) == @binding

        @source.with_lock do
          next unless Umi::FbigAdAttribution.valid_source?(@source, @conversation, @referral)
          next unless @source.content == @tapped_title && @source.created_at == @source_time
          next if note?(status: guard)

          clear_failure_notes if status == 'ok'
          @conversation.messages.create!(
            account_id: @conversation.account_id, inbox_id: @conversation.inbox_id,
            message_type: :outgoing, private: true, sender: nil,
            content: "Ad referral — message ##{@source.id}, #{@source_time.utc.iso8601}, ad #{@ad_id}\n\n#{body}",
            content_attributes: { MARKER => { 'source_message_id' => @source.id, 'ad_id' => @ad_id, 'status' => status } }
          )
        end
      end
    end
  end

  # content_attributes is a JSON column with a store coder: SQL key operators
  # cannot read its serialized JSON string. Always use the decoded accessor.
  def matching_notes
    @conversation.messages.reload.select do |message|
      marker = message.content_attributes[MARKER]
      marker.is_a?(Hash) && marker['source_message_id'] == @source.id && marker['ad_id'] == @ad_id
    end
  end

  def clear_failure_notes
    ids = matching_notes.select { |message| message.content_attributes.dig(MARKER, 'status') == 'error' }.map(&:id)
    Message.where(id: ids).delete_all if ids.any?
  end

  def note?(status:)
    matching_notes.any? { |message| status.nil? || message.content_attributes.dig(MARKER, 'status') == status }
  end

  def handle_failure(error) # rubocop:disable Metrics/CyclomaticComplexity
    reason = error.is_a?(Umi::Meta::AdWelcomeMessageService::Unavailable) ? error.message : error.class.name
    Rails.logger.error("[UMI-FBIG] stage=ad_context_failed conversation=#{@conversation&.id} reason=#{reason}")
    return unless @binding && @source && @ad_id

    write(Umi::Meta::AdContextNotePresenter.failure_body(reason), 'error', guard: nil)
  rescue StandardError => e
    Rails.logger.error("[UMI-FBIG] stage=ad_context_note_failed conversation=#{@conversation&.id} error=#{e.class}")
  end
end
