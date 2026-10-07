# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  base = Messages::Instagram::BaseMessageBuilder
  method = :set_conversation_based_on_inbox_config
  raise "UMI Instagram conversation serialization: #{base}##{method} changed — rebase the patch." unless base.private_method_defined?(method)

  [Messages::Instagram::Messenger::MessageBuilder, Messages::Instagram::MessageBuilder].each do |klass|
    if klass.instance_methods(false).include?(method) || klass.private_instance_methods(false).include?(method)
      raise "UMI Instagram conversation serialization: #{klass} overrides ##{method} — rebase the patch."
    end
  end

  base.prepend(Umi::InstagramConversationSerialization) unless base < Umi::InstagramConversationSerialization
end
