# frozen_string_literal: true

class Umi::Funnel::ReadbackJob < ApplicationJob
  queue_as :low
  discard_on(StandardError) { |job, error| Rails.logger.error("[umi-funnel] readback job #{job.arguments.first}: #{error.class}") }

  def perform(delivery_id)
    delivery = Umi::ConversionDelivery.find_by(id: delivery_id)
    Umi::Funnel::DeliveryService.new(delivery).confirm_scheduled if delivery
  rescue StandardError => e
    raise StandardError, e.class.name, cause: nil
  end
end
