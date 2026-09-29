# frozen_string_literal: true

module Umi::Funnel::SettlementMessages
  def create # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    attributes = params[:content_attributes]
    attributes = JSON.parse(attributes) if attributes.is_a?(String)
    if attributes.respond_to?(:except)
      params[:content_attributes] = attributes.except(Umi::Funnel::SettlementCommand::KEY, Umi::Funnel::SettlementCommand::RESPONSE_KEY)
    end
    operation = lambda do
      Message.transaction do
        super()
        Umi::Funnel::SettlementCommand.register(@message, Current.user || @resource) if @message&.persisted? && response.status < 400
      end
    end
    if ActiveModel::Type::Boolean.new.cast(params[:private]) && params[:content].to_s.strip.start_with?('/paid-in-chat')
      @conversation.contact.with_lock(&operation)
    else
      operation.call
    end
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end
end
