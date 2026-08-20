# frozen_string_literal: true

# A WhatsApp Cloud channel whose phone number was provisioned by another platform, which
# stays the number's owner. Chatwoot is a second app subscribed to the same WABA: it may
# subscribe itself and set its own app-scoped callback, but it must never touch anything
# scoped to the number rather than to the app.
#
# Opt in per channel with `provider_config['umi_foreign_owned'] = true`. A channel without
# the marker behaves exactly as upstream does.
module Umi::Channel::ForeignOwnedWhatsapp
  MARKER = 'umi_foreign_owned'

  class ForeignNumberCapabilityWrite < StandardError; end

  # Cast rather than test truthiness: the marker arrives through the JSON channel API, so
  # the string 'false' is a realistic value and is truthy in Ruby.
  def umi_foreign_owned?
    return false unless provider == 'whatsapp_cloud'

    ActiveModel::Type::Boolean.new.cast(provider_config[MARKER]).present?
  end

  # Meta scopes `POST /{phone-number-id}/settings` to the number, not to the calling app, so
  # turning WhatsApp calling on here changes a capability of a number UMI does not own. Unlike
  # the app-scoped writes this mode allows, the damaging outcome is the call *succeeding*, so
  # the toggle raising loudly on failure is no protection. The inbox controller renders this
  # message, so the admin who clicked the toggle learns it did not happen.
  #
  # Only the enable path writes it — `disable_voice_calling!` never calls `update_calling_status`,
  # and its webhook re-registration is app-scoped.
  def enable_voice_calling!
    if umi_foreign_owned?
      raise ForeignNumberCapabilityWrite,
            'Refusing to enable WhatsApp calling: the number is owned by another platform and calling status is a ' \
            'setting on the number, not on this app. Arrange it with the number owner instead.'
    end

    super
  end

  private

  # Saving the channel must not configure Meta. Upstream's after-create setup is the only
  # path that can register the phone number, and it reports failure as a log line plus a
  # reauthorization banner, so a channel that pushed nothing (or the wrong thing) still
  # looks created.
  #
  # Suppressing it also fixes the ordering. Meta refuses the phone-level callback override
  # until this app has its own callback URL saved, verified, and subscribed to `messages`
  # in its dashboard — and the URL and verify token that go there only exist once this row
  # is saved. So: save the channel (no Meta writes), read the callback URL and verify token
  # off it, configure the Meta app dashboard, then run setup explicitly and read the result.
  # `rake umi:whatsapp:foreign_owned_setup` walks that order.
  def should_auto_setup_webhooks?
    return false if umi_foreign_owned?

    super
  end
end
