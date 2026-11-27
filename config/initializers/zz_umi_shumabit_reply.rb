# frozen_string_literal: true

# UMI patch: in inboxes listed in InstallationConfig UMI_SHUMABIT_REPLY, the native Suggest reply button loads the
# private draft Shumabit already wrote, and a held wait completes through an authenticated re-check. Absent
# configuration keeps the native endpoint. Rationale: umi/app/services/shumabit_reply/loader.rb.
#
# Fail loud if upstream moves anything the loader relies on: a silently missing caller check could serve a draft to
# an automation token, and a missing hook would silently send listed inboxes to native generation.
Rails.application.routes.append do
  get '/api/v1/accounts/:account_id/umi/shumabit_reply/:conversation_display_id/completion',
      to: 'umi/shumabit_reply/completions#show'
end

Rails.application.config.to_prepare do
  controller = Api::V1::Accounts::Captain::TasksController
  raise 'UMI Shumabit reply: native reply_suggestion changed' unless controller.method_defined?(:reply_suggestion)
  raise 'UMI Shumabit reply: token authentication check changed' unless Api::BaseController.private_method_defined?(:authenticate_by_access_token?)
  raise 'UMI Shumabit reply: interactive session tracking changed' unless User.reflect_on_association(:user_sessions)
  unless DeviseTokenAuth::Concerns::SetUserByToken.protected_method_defined?(:set_user_by_token)
    raise 'UMI Shumabit reply: devise token validation changed'
  end
  raise 'UMI Shumabit reply: native conversation access changed' if ConversationPolicy.instance_method(:show?).owner == ApplicationPolicy

  controller.prepend(Umi::ShumabitReply::TasksLoader) unless controller.ancestors.include?(Umi::ShumabitReply::TasksLoader)
end
