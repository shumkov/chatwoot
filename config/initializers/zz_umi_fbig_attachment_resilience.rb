# frozen_string_literal: true

# UMI patch: don't lose an inbound FB/IG message when an attachment fails.
#
# Both Messenger-family builders (Messages::Facebook::MessageBuilder and
# Messages::Instagram::BaseMessageBuilder) download attachments inside the
# message-creation transaction; an expired Meta CDN URL (Down::Error) raised
# out of attach_file rolled back the message row and lost the whole message.
# Umi::MessengerAttachmentResilience rescues the download/attach step (only —
# a rescued DB error would poison the open transaction) so the message
# survives with whatever attachments could be stored.
#
# remove-when: upstream moves attachment downloads out of the message
# transaction (or rescues the download per attachment) in
# Messages::Messenger::MessageBuilder#attach_file.

Rails.application.reloader.to_prepare do
  unless Messages::Messenger::MessageBuilder.method_defined?(:attach_file)
    raise 'UMI zz_umi_fbig_attachment_resilience: Messages::Messenger::MessageBuilder#attach_file no longer exists — rebase the patch.'
  end

  unless Messages::Messenger::MessageBuilder.include?(Umi::MessengerAttachmentResilience)
    Messages::Messenger::MessageBuilder.prepend(Umi::MessengerAttachmentResilience)
  end
end
