# frozen_string_literal: true

class Umi::Funnel::DeliveryJob < ApplicationJob
  queue_as :low
  discard_on(StandardError) { |job, error| Rails.logger.error("[umi-funnel] delivery job #{job.arguments.first}: #{error.class}") }

  def perform(delivery_id)
    delivery = Umi::ConversionDelivery.find_by(id: delivery_id)
    return unless delivery

    service = Umi::Funnel::DeliveryService.new(delivery)
    service.dispatch(automatic: true) if service.ready_for_schedule?
  rescue StandardError => e
    begin
      service&.hold_preparation(e)
    rescue StandardError => hold_error
      e = hold_error
    end
    raise StandardError, e.class.name, cause: nil
  end
end
