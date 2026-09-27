# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  builders = [Messages::Facebook::MessageBuilder, Messages::Instagram::BaseMessageBuilder]
  builders.each do |builder|
    unless builder.private_method_defined?(:message_params)
      raise "UMI recovery provenance: #{builder}#message_params no longer exists — rebase the patch."
    end
  end

  [Messages::Instagram::Messenger::MessageBuilder, Messages::Instagram::MessageBuilder].each do |builder|
    next unless builder.instance_methods(false).include?(:message_params) || builder.private_instance_methods(false).include?(:message_params)

    raise "UMI recovery provenance: #{builder} overrides message_params — wire the patch directly."
  end

  builders.each do |builder|
    builder.prepend(Umi::FbigRecoveryProvenance) unless builder.include?(Umi::FbigRecoveryProvenance)
  end
end
