# frozen_string_literal: true

module Umi::LabelsApiAccount
  private

  # Labels redeclares the account callback after the inherited API access check.
  # Resolve membership before that check, retaining its native denial response.
  def validate_token_api_access
    current_account
    return if performed?

    super
  end
end

Rails.application.reloader.to_prepare do
  controller = Api::V1::Accounts::LabelsController
  unless controller.private_method_defined?(:current_account) && controller.private_method_defined?(:validate_token_api_access)
    raise 'UMI labels API account patch: upstream account access methods changed; rebase the patch.'
  end

  controller.prepend(Umi::LabelsApiAccount) unless controller < Umi::LabelsApiAccount
end
