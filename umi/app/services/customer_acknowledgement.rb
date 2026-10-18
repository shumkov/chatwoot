# frozen_string_literal: true

class Umi::CustomerAcknowledgement
  CONFIG_NAME = 'UMI_CUSTOMER_ACKNOWLEDGEMENTS'
  MARKER = 'umi_customer_acknowledgement'
  BOUNDARY = 'umi_acknowledgement_closed_message_id'
  DAY_COPY = "ขออภัยที่ทำให้คุณต้องรอนะคะ เราได้รับข้อความแล้วและจะรีบตอบกลับโดยเร็วที่สุดค่ะ\n\n" \
             'Sorry to keep you waiting. We’ve received your message and will reply as soon as possible.'
  NIGHT_COPY = 'ขอบคุณที่ติดต่อ UMI ค่ะ ทีมงานให้บริการทุกวัน 09:00–21:00 น. (เวลาประเทศไทย) ' \
               "เราจะกลับมาตอบข้อความตั้งแต่เวลา 09:00 น. ค่ะ\n\n" \
               'Thank you for contacting UMI. Our team is available daily, 09:00–21:00 Bangkok time. ' \
               'We’ll be back to reply from 09:00.'

  def self.configuration
    InstallationConfig.find_by(name: CONFIG_NAME)&.value
  end

  def self.schedule(message)
    settings = configuration
    return unless settings&.fetch('inbox_ids')&.include?(message.inbox_id)

    new(message, settings).schedule
  end

  def self.generation_for(settings, inbox_id)
    settings.fetch('inbox_started_at', {}).fetch(inbox_id.to_s, settings.fetch('started_at'))
  end

  def initialize(message, settings)
    @message = message
    @conversation = message.conversation
    @inbox = message.inbox
    @generation = self.class.generation_for(settings, @inbox.id)
    @started_at = Time.iso8601(@generation)
  end

  def schedule
    return unless eligible?(@message) && @message.created_at >= @started_at

    validate_configuration!
    mode = working_at?(@message.created_at) ? 'day' : 'night'
    due_at = mode == 'day' ? @message.created_at + 5.minutes : Time.current
    Umi::CustomerAcknowledgementJob.set(wait_until: due_at).perform_later(@message.id, @generation, mode)
  end

  def perform(mode)
    validate_configuration!
    @conversation.with_lock { acknowledge(mode) }
  end

  private

  def acknowledge(mode) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    @message.reload
    return unless @conversation.open? && eligible?(@message) && @message.created_at >= @started_at
    return if @message.created_at < 24.hours.ago || @conversation.label_list.include?('spam')
    return unless working_at?(Time.current) == (mode == 'day')

    messages = current_messages
    return unless messages.any? { |item| item.id == @message.id }
    return if messages.any? { |item| item.content_attributes[MARKER] }

    first = messages.find { |item| eligible?(item) }
    return unless first
    return if mode == 'day' && first.created_at > 5.minutes.ago
    return if mode == 'night' && recent_human_reply?

    @conversation.messages.create!(account_id: @conversation.account_id, inbox_id: @inbox.id,
                                   message_type: :template, content: mode == 'day' ? DAY_COPY : NIGHT_COPY,
                                   content_attributes: { MARKER => { mode: mode, first_message_id: first.id } })
  end

  def recent_human_reply?
    @conversation.messages.where(created_at: 5.minutes.ago..).includes(:sender).any? { |item| successful_human?(item) }
  end

  def successful_human?(item)
    !item.private? && !item.failed? && !item.content_attributes['deleted'] &&
      !item.content_attributes['umi_recovered'] && item.send(:human_response?) && !item.send(:bot_response?)
  end

  def eligible?(message) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    message.incoming? && !message.private? && !message.auto_reply_email? &&
      !message.content_attributes['deleted'] && !message.content_attributes['umi_recovered'] &&
      !message.content_attributes['is_unsupported'] && (message.content.present? || message.attachments.any?) &&
      %w[story_mention ig_story ig_post].exclude?(message.content_attributes['image_type']) &&
      (message.content_attributes['image_type'] == 'ig_story_reply' ||
        message.attachments.none? { |attachment| %w[story_mention share ig_post ig_reel ig_story].include?(attachment.file_type) })
  end

  def current_messages
    boundary = @conversation.additional_attributes.fetch(BOUNDARY, 0)
    messages = @conversation.messages.where('id > ?', boundary).where(created_at: @started_at..)
                            .includes(:sender, :attachments).order(:created_at, :id).to_a
    last_human = messages.reverse.find { |item| successful_human?(item) }
    return messages unless last_human

    messages.drop(messages.index(last_human) + 1)
  end

  def working_at?(time)
    local = time.in_time_zone(@inbox.timezone)
    hours = @inbox.working_hours.find_by!(day_of_week: local.wday)
    return false if hours.closed_all_day?
    return true if hours.open_all_day?

    minutes = (local.hour * 60) + local.min
    minutes >= (hours.open_hour * 60) + hours.open_minutes && minutes < (hours.close_hour * 60) + hours.close_minutes
  end

  def validate_configuration! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    @inbox.reload
    supported_channel = %w[Channel::FacebookPage Channel::WebWidget Channel::Line].include?(@inbox.channel_type) ||
                        (@inbox.channel_type == 'Channel::TwilioSms' && @inbox.channel.whatsapp?)
    unless supported_channel && @inbox.working_hours_enabled? &&
           @inbox.out_of_office_message.blank? && !@inbox.greeting_enabled?
      raise ArgumentError, 'Customer acknowledgements require a supported inbox with business hours and native auto-replies disabled'
    end
    raise ArgumentError, 'Customer acknowledgement copy requires Asia/Bangkok hours' unless @inbox.timezone == 'Asia/Bangkok'

    unless @inbox.working_hours.count == 7 && @inbox.working_hours.all? do |hours|
      !hours.closed_all_day? && !hours.open_all_day? &&
      [hours.open_hour, hours.open_minutes, hours.close_hour, hours.close_minutes] == [9, 0, 21, 0]
    end
      raise ArgumentError, 'Customer acknowledgement copy requires daily 09:00–21:00 hours'
    end
    return unless @inbox.channel_type == 'Channel::FacebookPage' &&
                  GlobalConfigService.load('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil)

    raise ArgumentError, 'Automated acknowledgements cannot use the global HUMAN_AGENT messaging tag'
  end
end
