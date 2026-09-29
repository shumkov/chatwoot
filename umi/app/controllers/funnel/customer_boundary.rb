# frozen_string_literal: true

module Umi::Funnel::CustomerBoundary
  extend ActiveSupport::Concern

  included do
    prepend_before_action :protect_umi_customer_input
    after_action :filter_umi_customer_response
  end

  private

  def protect_umi_customer_input
    Umi::Funnel::CustomerPayload.validate!(params)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def filter_umi_customer_response
    return unless response.media_type == 'application/json' && response.body.present?

    response.body = Umi::Funnel::CustomerPayload.filter(JSON.parse(response.body)).to_json
  end
end
