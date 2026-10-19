# frozen_string_literal: true

module Umi::Shopify::ProductRetry
  def retry
    @message ||= @conversation.messages.find_by(id: permitted_params[:id])
    return super unless @message&.content_attributes&.key?('umi_product_card')

    retry_product_share
  end

  private

  def retry_product_share
    message.with_lock do
      state = message.content_attributes.dig('umi_product_delivery', 'state')
      next render json: { error: 'Reconcile the product share before retry.' }, status: :conflict unless state == 'rejected'

      verify_product_requester!
      message.update!(content_attributes: message.content_attributes.except('umi_product_delivery'))
      Messages::StatusUpdateService.new(message, 'sent').perform
      SendReplyJob.perform_later(message.id)
    end
    head :accepted unless performed?
  rescue ArgumentError, ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :conflict
  end

  def verify_product_requester!
    card = message.content_attributes.fetch('umi_product_card')
    requester = Umi::Shopify::ProductSource.verify!(@conversation.messages.find(card.fetch('source_id')), card)
    raise ArgumentError, 'Staff requester changed.' unless requester == card['requested_by']
  end
end
