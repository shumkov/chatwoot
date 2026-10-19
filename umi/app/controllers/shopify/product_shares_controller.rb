# frozen_string_literal: true

class Umi::Shopify::ProductSharesController < Api::V1::Accounts::Conversations::BaseController
  before_action :bridge_context
  rescue_from ArgumentError, with: :invalid_command

  def show
    render json: receipt(existing_message)
  end

  def create
    @source.with_lock do
      facts = params.require(:facts).permit(:product_id, :title, :variant_id, :variant_title, :image_url, :canonical_url,
                                            :snapshot_at, price: %i[amount currency market]).to_h
      requester = Umi::Shopify::ProductSource.verify!(@source, facts)
      @message = existing_message || Umi::Shopify::ProductCardService.new(conversation: @conversation, facts: facts,
                                                                          source_id: @source.id, requested_by: requester,
                                                                          sender: Current.user).perform
      @source.update!(content_attributes: @source.content_attributes.merge('umi_product_share_message_id' => @message.id))
    end
    render json: receipt(@message)
  end

  private

  def bridge_context
    return head :forbidden unless Current.user.is_a?(User) && Current.user.id.to_s == ENV['UMI_COMMERCE_BRIDGE_USER_ID'] &&
                                  Current.account.id == ENV.fetch('UMI_COMMERCE_ACCOUNT_ID', '1').to_i &&
                                  product_inbox?

    @source = @conversation.messages.find(params.require(:source_message_id))
  end

  def product_inbox?
    channel = @conversation.inbox.channel
    return @conversation.inbox_id == ENV.fetch('UMI_COMMERCE_META_INBOX_ID', '2').to_i if channel.is_a?(Channel::FacebookPage)

    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud' &&
      @conversation.inbox_id == ENV.fetch('UMI_COMMERCE_CLOUD_INBOX_ID', '3').to_i
  end

  def existing_message
    id = @source.content_attributes['umi_product_share_message_id']
    @conversation.messages.find(id) if id
  end

  def receipt(message)
    state = message&.content_attributes&.dig('umi_product_delivery', 'state') || (message ? 'queued' : 'not_found')
    state = message.source_id.present? ? 'accepted' : 'ambiguous' if state == 'dispatching'
    { status: state, message_id: message&.id, text: "Product share #{state}." }
  end

  def invalid_command(error)
    render json: { status: 'rejected', text: error.message }, status: :unprocessable_entity
  end
end
