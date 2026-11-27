# frozen_string_literal: true

# Completion of a held Suggest reply tap. A proxy calls it with the client's own credentials after the bridge's wait
# ends; it repeats every check on current state and never offers another wait. Calling it directly is harmless: it is
# the same read-only loader.
class Umi::ShumabitReply::CompletionsController < Api::V1::Accounts::BaseController
  include Umi::ShumabitReply::Rendering

  def show
    config = Umi::ShumabitReply::Configuration.current
    log_invalid_shumabit_config unless config.off? || config.valid?
    conversation = Current.account.conversations.find_by(display_id: params[:conversation_display_id])
    return render_shumabit_unavailable(conversation, :completion) unless conversation && config.listed?(conversation.inbox_id)

    render_shumabit_reply(conversation, config, :completion)
  end
end
