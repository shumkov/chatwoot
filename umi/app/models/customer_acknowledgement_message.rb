# frozen_string_literal: true

module Umi::CustomerAcknowledgementMessage
  extend ActiveSupport::Concern

  included do
    after_create_commit :schedule_umi_customer_acknowledgement
  end

  private

  def schedule_umi_customer_acknowledgement
    Umi::CustomerAcknowledgement.schedule(self) if incoming? && !private?
  end
end
