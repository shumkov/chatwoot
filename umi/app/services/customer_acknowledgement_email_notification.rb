# frozen_string_literal: true

module Umi::CustomerAcknowledgementEmailNotification
  def perform
    return if message.inbox.channel_type == 'Channel::WebWidget' &&
              message.content_attributes[Umi::CustomerAcknowledgement::MARKER].present?

    super
  end
end
