# frozen_string_literal: true

# Messages::Facebook::MessageBuilder and Messages::Instagram::BaseMessageBuilder
# create the message and process its attachments inside one DB transaction.
# Meta CDN attachment URLs expire quickly, so a failed download raised out of
# attach_file, rolled back the already-created message row, and the whole
# inbound message — text included — was permanently lost (Meta does not
# redeliver webhooks).
#
# The rescue is deliberately scoped to attach_file (the download + blob attach
# step) and not the whole process_attachment: rescuing a DB-level failure such
# as ActiveRecord::StatementInvalid would leave the surrounding transaction
# aborted and the message would die at COMMIT anyway, just more confusingly.
# The attachment row is saved before the download, so it survives with its
# external_url; the message persists with whatever attachments could be stored.
# Mirrors the pattern upstream already uses for Instagram story attachments.
module Umi::MessengerAttachmentResilience
  def attach_file(attachment, file_url)
    super
  rescue Down::Error, StandardError => e
    Rails.logger.warn(
      "[UMI-FBIG] stage=attachment_failed inbox_id=#{@inbox&.id} mid=#{@message&.source_id} " \
      "error=#{e.class}: #{e.message}"
    )
    ChatwootExceptionTracker.new(e, account: @inbox&.account).capture_exception
    nil
  end
end
