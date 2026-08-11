# frozen_string_literal: true

# Wires Umi::FbigAdAttribution into the inbound FB/IG message path.
#
# Loads before zz_umi_fbig_trace.rb (initializers run alphabetically), so the
# trace prepend stays outermost and its stage=persisted line still lands after
# attribution has run.
Rails.application.reloader.to_prepare do
  unless Integrations::Facebook::MessageParser.method_defined?(:message_referral)
    Integrations::Facebook::MessageParser.prepend(Umi::FbigAdAttribution::MessageParser)
  end

  Messages::Facebook::MessageBuilder.prepend(Umi::FbigAdAttribution::FacebookBuilder)
  # One prepend covers both Instagram paths — neither subclass overrides
  # message_params or perform.
  Messages::Instagram::BaseMessageBuilder.prepend(Umi::FbigAdAttribution::InstagramBuilder)
end
