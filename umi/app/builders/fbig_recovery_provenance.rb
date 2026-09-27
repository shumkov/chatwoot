# frozen_string_literal: true

module Umi::FbigRecoveryProvenance
  private

  def message_params
    params = super
    context = Umi::Fbig::RecoveryContext
    return params unless context.inbox_id.present? && context.source_id.present?
    return params unless params[:inbox_id] == context.inbox_id && params[:source_id] == context.source_id
    return params unless params[:message_type].to_s == 'incoming'

    params.merge(content_attributes: params[:content_attributes].to_h.merge(
      umi_recovered: true,
      external_created_at: context.source_created_at
    ))
  end
end
