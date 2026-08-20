# frozen_string_literal: true

# Keeps Chatwoot's webhook setup inside the app-scoped subset of the Cloud API when the
# number belongs to another platform.
#
# Allowed, because Meta scopes them to the calling app (confirmed live against a two-app
# WABA — docs/UMI-SHARED-NUMBER-SPEC.md §1.2):
#   POST /{waba-id}/subscribed_apps        — subscribes this app, leaves siblings alone
#   POST /{phone-number-id} webhook_config — sets this app's own callback override
#
# Forbidden, because it is scoped to the number and not to the app:
#   POST /{phone-number-id}/register       — writes a PIN into the number's two-step
#                                            verification namespace. Chatwoot invents that
#                                            PIN with SecureRandom, so a *successful* call
#                                            is the damaging one: it resets the owner's PIN
#                                            and breaks their next re-registration.
module Umi::Whatsapp::ForeignOwnedWebhookSetup
  class ForeignRegistrationAttempt < StandardError; end

  # Meta rejects the phone-level override until the calling app has a verified callback URL
  # and the `messages` field subscribed in its own dashboard panel. Its message blames the
  # WABA subscription, which this service made successfully moments earlier, so an operator
  # who trusts it re-runs setup forever. Say what actually has to change instead.
  OVERRIDE_PREREQUISITE_SIGNATURE = 'Before override the current callback uri'
  OVERRIDE_PREREQUISITE_HINT = 'The WABA subscription above succeeded; this is a dashboard prerequisite, not a missing ' \
                               'subscription. In this app\'s Meta dashboard under WhatsApp > Configuration > Webhook, ' \
                               'save the callback URL and verify token, click "Verify and save", and toggle `messages` ' \
                               'to Subscribed. Then run this setup again.'

  # Upstream registers the phone number whenever verification or the health check says no —
  # and both of those rescue API failures to false. Drop straight to the callback-only path.
  def perform
    return super unless umi_foreign_owned_channel?

    register_callback
  end

  # The rescue deliberately wraps only the foreign-owned branch: a method-level rescue would
  # also rewrite the error every other Cloud channel raises.
  def register_callback
    return super unless umi_foreign_owned_channel?

    begin
      super
    rescue StandardError => e
      raise unless e.message.include?(OVERRIDE_PREREQUISITE_SIGNATURE)

      raise "#{e.message} — #{OVERRIDE_PREREQUISITE_HINT}"
    end
  end

  private

  # Raised, not skipped: this sits above the caller's own `rescue StandardError` that logs
  # "but continuing", so a silent return would be indistinguishable from a successful
  # registration. Any path that reaches here on a foreign-owned number is a bug worth stopping.
  def register_phone_number
    if umi_foreign_owned_channel?
      raise ForeignRegistrationAttempt,
            "Refusing to register phone number #{@channel.provider_config['phone_number_id']}: " \
            'the number is owned by another platform and registering it would reset its two-step PIN.'
    end

    super
  end

  # These guards run ahead of upstream's `validate_parameters!`, which is what turns a nil
  # channel into "Channel is required" — so this has to tolerate one rather than raise first.
  def umi_foreign_owned_channel?
    @channel.respond_to?(:umi_foreign_owned?) && @channel.umi_foreign_owned?
  end
end
