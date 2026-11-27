# frozen_string_literal: true

# Prepended to the native Captain tasks controller: in an inbox listed in InstallationConfig UMI_SHUMABIT_REPLY, the
# Suggest reply button loads the draft Shumabit already wrote instead of generating one. Unlisted inboxes and every
# other Captain task keep the native behaviour. A present but invalid configuration answers `unavailable` for every
# Suggest reply rather than falling back to generation.
module Umi::ShumabitReply::TasksLoader
  include Umi::ShumabitReply::Rendering

  def reply_suggestion
    config = Umi::ShumabitReply::Configuration.current
    return super if config.off?

    unless config.valid?
      log_invalid_shumabit_config
      return render_shumabit_unavailable(nil, :tap)
    end

    conversation = Current.account.conversations.find_by(display_id: params[:conversation_display_id])
    return super unless conversation && config.listed?(conversation.inbox_id)

    render_shumabit_reply(conversation, config, :tap)
  end
end
