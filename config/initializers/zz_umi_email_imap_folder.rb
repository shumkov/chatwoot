# frozen_string_literal: true

# UMI patch: let an Email inbox fetch from a specific Gmail label instead of the hardcoded INBOX.
#
# Stock Chatwoot's Imap::BaseFetchEmailService#build_imap_client always does imap.select('INBOX'),
# so a shared "reader" mailbox (shumabit@, a member of the info@/support@ Google Groups) would pull
# its ENTIRE inbox into Chatwoot. Setting the channel's provider_config['imap_folder'] to a label
# (e.g. 'Chatwoot') + a Gmail filter that labels only the group mail scopes ingestion to that label,
# leaving the mailbox's other inbox mail untouched — no archiving, no extra Workspace seat.
#
# Two prepends make this safe:
#   Umi::Imap::ConfigurableFolder     — reads the label named in provider_config['imap_folder'].
#   Umi::Imap::PreserveProviderConfig — keeps imap_folder across an OAuth token refresh (stock
#                                       BaseRefreshOauthTokenService overwrites the whole config).
# remove-when: upstream Chatwoot adds a per-inbox source folder/label for the email channel.

Rails.application.reloader.to_prepare do
  unless Imap::BaseFetchEmailService.private_method_defined?(:build_imap_client)
    raise 'UMI zz_umi_email_imap_folder: Imap::BaseFetchEmailService#build_imap_client no longer exists — rebase the patch.'
  end
  unless BaseRefreshOauthTokenService.method_defined?(:update_channel_provider_config)
    raise 'UMI zz_umi_email_imap_folder: BaseRefreshOauthTokenService#update_channel_provider_config no longer exists — rebase.'
  end

  {
    Imap::BaseFetchEmailService => Umi::Imap::ConfigurableFolder,
    BaseRefreshOauthTokenService => Umi::Imap::PreserveProviderConfig
  }.each { |klass, mod| klass.prepend(mod) unless klass.include?(mod) }
end
