# frozen_string_literal: true

module Umi::Funnel::ConversationProjection
  extend ActiveSupport::Concern

  included do
    before_validation :protect_umi_sales_status
  end

  def project_umi_sales_status!(status)
    @umi_projecting_sales_status = true
    update!(custom_attributes: custom_attributes.merge('umi_sales_status' => status))
    projected = label_list - %w[lead-qualified lead-converted]
    projected << 'lead-qualified' if status == 'qualified'
    projected << 'lead-converted' if status == 'purchased'
    update!(label_list: projected)
  ensure
    @umi_projecting_sales_status = false
  end

  private

  def protect_umi_sales_status
    return if @umi_projecting_sales_status

    old = custom_attributes_in_database.to_h['umi_sales_status']
    current = custom_attributes.to_h
    if current.key?('umi_sales_status') && current['umi_sales_status'] != old
      errors.add(:custom_attributes, 'umi_sales_status is managed by the funnel')
    elsif old.present? && !current.key?('umi_sales_status')
      self.custom_attributes = current.merge('umi_sales_status' => old)
    end
  end
end
