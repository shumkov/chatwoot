# frozen_string_literal: true

module Umi::InstagramConversationSerialization
  private

  def set_conversation_based_on_inbox_config
    # A second message must see the first builder's committed conversation,
    # including when attachment processing keeps its transaction open.
    contact.with_lock { super }
  end
end
