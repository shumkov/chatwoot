# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  controller = Api::V1::Accounts::ConversationsController
  raise 'UMI funnel: conversation custom attributes action changed' unless controller.method_defined?(:custom_attributes)

  controller.prepend(Umi::Funnel::OperatorStatus) unless controller.include?(Umi::Funnel::OperatorStatus)
end
