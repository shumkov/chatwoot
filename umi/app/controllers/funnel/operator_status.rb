# frozen_string_literal: true

module Umi::Funnel::OperatorStatus
  def custom_attributes
    return super unless Umi::Funnel::Configuration.enabled?(@conversation.account_id) && Current.user.is_a?(User)

    attributes = params.permit(custom_attributes: {})[:custom_attributes]
    return super unless attributes

    @conversation.contact.with_lock do
      @conversation.reload.with_lock do
        confirm_umi_sales_status!(attributes) if params[:changed_attribute_key] == 'umi_sales_status'
        managed = @conversation.custom_attributes.slice('umi_sales_status')
        @conversation.update!(custom_attributes: attributes.to_h.except('umi_sales_status').merge(managed))
      end
    end
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  private

  def confirm_umi_sales_status!(attributes)
    status = attributes['umi_sales_status']
    raise ArgumentError, 'Sales status cannot be removed' if status.blank?

    previous = @conversation.custom_attributes['umi_sales_status']
    return if status == previous

    raise ArgumentError, 'Payment status is managed by Shopify' if %w[order_placed purchased].include?(previous)

    messages = @conversation.messages.incoming.where(private: false).where('created_at >= ?', Umi::Funnel::Configuration.started_at)
                            .order(created_at: :desc, id: :desc)
    evidence = messages.detect { |message| !message.content_attributes['umi_recovered'] }
    Umi::Funnel::ConversationTransition.new(conversation: @conversation, status: status, actor: Current.user,
                                            reason: 'Operator confirmed sales status in conversation sidebar',
                                            evidence_message_ids: evidence ? [evidence.id] : []).perform
  end
end
