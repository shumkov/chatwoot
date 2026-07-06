# frozen_string_literal: true

# Fetch an Email inbox's mail from a specific IMAP folder / Gmail label instead of the
# hardcoded INBOX. Prepended onto Imap::BaseFetchEmailService (see zz_umi_email_imap_folder).
#
# The folder is read from the channel's provider_config['imap_folder']; when unset (or 'INBOX')
# behaviour is identical to stock Chatwoot. Relies on Umi::Imap::PreserveProviderConfig so an
# OAuth token refresh triggered mid-fetch keeps the imap_folder key rather than overwriting the
# whole provider_config (which would silently revert the inbox to reading the entire INBOX).
module Umi::Imap::ConfigurableFolder
  private

  def build_imap_client
    imap = super
    folder = channel.try(:provider_config)&.dig('imap_folder').presence
    return imap if folder.nil? || folder == 'INBOX'

    imap.select(folder)
    imap
  rescue StandardError
    # A missing / non-"Show in IMAP" label fails the fetch loudly (rather than silently
    # falling back to the whole inbox); close the connection super opened so it doesn't leak.
    imap&.disconnect
    raise
  end
end
