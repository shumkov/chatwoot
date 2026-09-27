# frozen_string_literal: true

class Umi::Funnel::Configuration
  STATUSES = %w[unevaluated engaged qualified inactive not_sales order_placed purchased].freeze

  def self.account_ids
    value = ENV.fetch('UMI_FUNNEL_ACCOUNT_IDS', '')
    return [] if value.blank?

    ids = value.split(',', -1)
    raise ArgumentError, 'Invalid UMI_FUNNEL_ACCOUNT_IDS' unless ids.all? { |id| id.match?(/\A[1-9]\d*\z/) }

    started_at
    ids.map(&:to_i).uniq
  end

  def self.started_at
    value = ENV.fetch('UMI_FUNNEL_STARTED_AT')
    raise ArgumentError, 'UMI_FUNNEL_STARTED_AT must use UTC Z' unless value.end_with?('Z')

    Time.iso8601(value)
  end

  def self.enabled?(account_id)
    account_ids.include?(account_id)
  end

  def self.provision!(account)
    definition = account.custom_attribute_definitions.find_or_initialize_by(attribute_key: 'umi_sales_status',
                                                                            attribute_model: 'conversation_attribute')
    if definition.persisted?
      raise ArgumentError, 'Incompatible umi_sales_status definition' unless definition.list? && definition.attribute_values == STATUSES
    else
      definition.update!(attribute_display_name: 'Sales status', attribute_display_type: 'list', attribute_values: STATUSES)
    end
    description = 'Confirm qualification here after reviewing the conversation. Order placed and purchased are updated automatically by Shopify.'
    definition.update!(attribute_description: description) unless definition.attribute_description == description
  end
end
