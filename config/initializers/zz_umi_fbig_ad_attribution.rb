# frozen_string_literal: true

# Wires Umi::FbigAdAttribution into the inbound FB/IG message path.
#
# Loads before zz_umi_fbig_trace.rb (initializers run alphabetically), so the
# trace prepend stays outermost and its stage=persisted line still lands after
# attribution has run.
Rails.application.reloader.to_prepare do
  targets = {
    # `message_referral` is the method this patch adds; guard an upstream
    # parser method instead so a missing target still fails loudly.
    Integrations::Facebook::MessageParser => [:identifier],
    Messages::Facebook::MessageBuilder => [:perform, :message_params],
    Messages::Instagram::BaseMessageBuilder => [:perform, :message_params],
    Messages::Instagram::Messenger::MessageBuilder => [:perform, :message_params],
    Messages::Instagram::MessageBuilder => [:perform, :message_params]
  }

  targets.each do |klass, methods|
    methods.each do |method|
      next if klass.method_defined?(method) || klass.private_method_defined?(method)

      raise "UMI zz_umi_fbig_ad_attribution: #{klass}##{method} no longer exists — rebase the patch."
    end
  end

  [Messages::Instagram::Messenger::MessageBuilder, Messages::Instagram::MessageBuilder].each do |klass|
    next unless klass.instance_methods(false).intersect?(%i[perform message_params]) ||
                klass.private_instance_methods(false).intersect?(%i[perform message_params])

    raise "UMI zz_umi_fbig_ad_attribution: #{klass} overrides BaseMessageBuilder#perform/message_params — wire the patch directly."
  end

  unless Integrations::Facebook::MessageParser.include?(Umi::FbigAdAttribution::MessageParser)
    Integrations::Facebook::MessageParser.prepend(Umi::FbigAdAttribution::MessageParser)
  end

  unless Messages::Facebook::MessageBuilder.include?(Umi::FbigAdAttribution::FacebookBuilder)
    Messages::Facebook::MessageBuilder.prepend(Umi::FbigAdAttribution::FacebookBuilder)
  end
  # One prepend covers both Instagram paths — neither subclass overrides
  # message_params or perform.
  unless Messages::Instagram::BaseMessageBuilder.include?(Umi::FbigAdAttribution::InstagramBuilder)
    Messages::Instagram::BaseMessageBuilder.prepend(Umi::FbigAdAttribution::InstagramBuilder)
  end
end
