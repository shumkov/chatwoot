# frozen_string_literal: true

module Umi::Funnel::CustomerPublicMessages
  private

  def set_message
    @message = @conversation.messages.chat.find(params[:id])
  end
end
