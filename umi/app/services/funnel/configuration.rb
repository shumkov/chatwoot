# frozen_string_literal: true

class Umi::Funnel::Configuration
  STATUSES = %w[unevaluated engaged qualified inactive not_sales order_placed purchased].freeze

  ROLES = { 'umi_vip' => 'vip', 'umi_influencer' => 'influencer', 'umi_model' => 'model',
            'umi_wholesale' => 'wholesale', 'umi_high_value' => 'high-value' }.freeze
  ROLE_VALUES = %w[unknown yes no].freeze
  STAGES = %w[unclassified non_buyer chooser seeker client repeat].freeze
  CUSTOMER_LABELS = (%w[chooser seeker client repeat barter] + ROLES.values).freeze
  PROTECTED_LABELS = (CUSTOMER_LABELS + %w[lead-qualified lead-converted source-paid-ads]).freeze
  DERIVED_FIELDS = %w[umi_funnel_stage umi_paid_order_count umi_paid_history_complete umi_payment_snapshot_at umi_barter_history].freeze
  CONTACT_FIELDS = (ROLES.keys + DERIVED_FIELDS).freeze
  TECHNICAL_KEYS = %w[umi_klaviyo_sync umi_customer_projection umi_klaviyo_profile_id umi_klaviyo_binding umi_profile_redacted].freeze

  def self.customer_context_enabled?(account_id)
    value = ENV.fetch('UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS', '')
    return false if value.blank?

    ids = value.split(',', -1)
    raise ArgumentError, 'Invalid UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS' unless ids.all? { |id| id.match?(/\A[1-9]\d*\z/) }

    ids.map(&:to_i).include?(account_id)
  end

  def self.provision_customer_context!(account)
    definitions = ROLES.keys.index_with { |_key| ['list', ROLE_VALUES] }.merge(
      'umi_funnel_stage' => ['list', STAGES], 'umi_paid_order_count' => ['number', []],
      'umi_paid_history_complete' => ['checkbox', []], 'umi_payment_snapshot_at' => ['date', []],
      'umi_barter_history' => ['checkbox', []]
    )
    account.with_lock do
      definitions.each { |key, (type, values)| provision_customer_definition!(account, key, type, values) }
      (PROTECTED_LABELS + %w[intent-size-advice intent-color-advice intent-product-details intent-ready-to-order
                             support-order-tracking support-exchange support-refund support-complaint
                             support-after-sales support-special-request spam]).each do |title|
        account.labels.find_or_create_by!(title: title) do |label|
          label.color = '#64748b'
          label.show_on_sidebar = true
        end
      end
    end
  end

  def self.provision_customer_definition!(account, key, type, values)
    definition = account.custom_attribute_definitions.find_or_initialize_by(attribute_key: key, attribute_model: 'contact_attribute')
    if definition.persisted?
      raise ArgumentError, "Incompatible #{key} definition" unless definition.attribute_display_type == type && definition.attribute_values == values

      return
    end

    description = ROLES.key?(key) ? 'Unknown, yes or explicit no.' : 'Managed automatically from verified customer facts.'
    definition.update!(attribute_display_name: key.delete_prefix('umi_').humanize, attribute_display_type: type,
                       attribute_values: values, attribute_description: description)
  end

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
    provision_customer_context!(account) if customer_context_enabled?(account.id)
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
