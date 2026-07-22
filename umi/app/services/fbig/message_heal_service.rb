# frozen_string_literal: true

# Replays a single message the reconciliation found missing (inbound only)
# through the regular webhook pipeline, as if the webhook had arrived: fetch
# the message from the Graph API, synthesize the webhook-shaped payload, and
# hand it to the same builders the live path uses — contact creation,
# conversation selection, dedup and attachment degradation all behave exactly
# as for a real webhook. The recovered row is stamped
# content_attributes.umi_recovered=true; its created_at is the heal time (the
# builders don't take historical timestamps), the original send time stays in
# the reconcile log line and in Meta's thread.
class Umi::Fbig::MessageHealService
  def initialize(channel, platform)
    @channel = channel
    @platform = platform
  end

  # Returns :healed, or a symbol naming why the mid was skipped (the caller
  # logs it; the detection line already exists either way). Best-effort by
  # design: even an auth error just skips the mid — the platform-level
  # stand-down belongs to the detection scan, and the detection line for this
  # mid is already on record.
  def heal(mid)
    detail = fetch_detail(mid)
    return :content_unavailable if detail.nil?
    # A late webhook (or a previous heal) may have won the race since the
    # scan. Deliberately a GLOBAL source_id check (stricter than detection's
    # account scope): for a write path, "somewhere already" must mean skip.
    return :already_present if Message.exists?(source_id: mid)

    replay(detail)
    message = Message.find_by(source_id: mid)
    return :not_persisted unless message

    message.update(content_attributes: message.content_attributes.merge(umi_recovered: true))
    log_healed(mid, message)
    :healed
  rescue StandardError => e
    Rails.logger.warn("[UMI-FBIG] stage=heal_error mid=#{mid} error=#{e.class}: #{e.message}")
    :error
  end

  private

  def fetch_detail(mid)
    api.get_object(mid, { fields: 'id,created_time,from,message,attachments' })
  rescue StandardError
    nil
  end

  def replay(detail)
    if @platform == 'instagram'
      Instagram::Messenger::MessageText.new(instagram_messaging(detail), @channel).perform
    else
      parsed = Integrations::Facebook::MessageParser.new({ messaging: facebook_messaging(detail) }.to_json)
      Messages::Facebook::MessageBuilder.new(parsed, @channel.inbox).perform
    end
  end

  def instagram_messaging(detail)
    {
      sender: { id: detail.dig('from', 'id') },
      recipient: { id: @channel.instagram_id },
      timestamp: detail['created_time'],
      message: { mid: detail['id'], text: detail['message'] }.merge(attachments_part(detail))
    }.with_indifferent_access
  end

  def facebook_messaging(detail)
    {
      sender: { id: detail.dig('from', 'id') },
      recipient: { id: @channel.page_id },
      timestamp: detail['created_time'],
      message: { mid: detail['id'], text: detail['message'] }.merge(attachments_part(detail))
    }
  end

  def attachments_part(detail)
    mapped = Array(detail.dig('attachments', 'data')).filter_map { |att| webhook_attachment(att) }
    mapped.empty? ? {} : { attachments: mapped }
  end

  # The Conversations API attachment shape differs from the webhook shape;
  # map best-effort and skip what can't be mapped — the text still heals.
  def webhook_attachment(att)
    if att.dig('image_data', 'url')
      { type: 'image', payload: { url: att.dig('image_data', 'url') } }
    elsif att.dig('video_data', 'url')
      { type: 'video', payload: { url: att.dig('video_data', 'url') } }
    elsif att['file_url']
      { type: 'file', payload: { url: att['file_url'] } }
    end
  end

  def log_healed(mid, message)
    Rails.logger.warn("[UMI-FBIG] stage=healed platform=#{@platform} mid=#{mid} message_id=#{message.id}")
  end

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
