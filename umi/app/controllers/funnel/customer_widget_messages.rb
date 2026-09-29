# frozen_string_literal: true

module Umi::Funnel::CustomerWidgetMessages
  private

  def set_message
    @message = Message.chat.where(conversation_id: conversations.select(:id)).find(permitted_params[:id])
  end
end
