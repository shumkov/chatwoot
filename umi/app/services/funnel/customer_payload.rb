# frozen_string_literal: true

class Umi::Funnel::CustomerPayload
  def self.filter(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, entry), result|
        next if Umi::Funnel::Configuration::TECHNICAL_KEYS.include?(key.to_s)

        result[key] = filter(entry)
      end
    when Array then value.map { |entry| filter(entry) }
    else value
    end
  end

  def self.validate!(params)
    custom = params[:custom_attributes]
    keys = custom.respond_to?(:keys) ? custom.keys : Array(custom)
    forbidden = Umi::Funnel::Configuration::CONTACT_FIELDS + Umi::Funnel::Configuration::TECHNICAL_KEYS + ['umi_sales_status']
    additional = params[:additional_attributes]
    keys += additional.keys if additional.respond_to?(:keys)
    raise ArgumentError, 'Customer context is managed by the account' if keys.map(&:to_s).intersect?(forbidden)

    validate!(params[:contact]) if params[:contact].respond_to?(:keys)
  end
end
