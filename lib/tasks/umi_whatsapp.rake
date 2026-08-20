# frozen_string_literal: true

# UMI: explicit Meta setup for a WhatsApp Cloud channel on a number another platform owns.
#
#   bundle exec rake 'umi:whatsapp:foreign_owned_setup[42]'
#
# Foreign-owned channels skip the after-create webhook setup, so this is how they get
# configured. It subscribes this app to the WABA and sets this app's own phone-level
# callback override; it never registers the phone number. Idempotent — re-run it after
# fixing the dashboard, or after FRONTEND_URL changes.
#
# Run it once before the Meta dashboard is configured: it prints the callback URL and
# verify token to paste there, then fails with the prerequisite Meta enforces. Configure
# the dashboard, run it again, and it succeeds. Failures abort — nothing here is swallowed.
namespace :umi do
  namespace :whatsapp do
    desc 'Configure Meta for a foreign-owned WhatsApp Cloud channel (never registers the phone number)'
    task :foreign_owned_setup, [:inbox_id] => :environment do |_t, args|
      inbox = Inbox.find(args.fetch(:inbox_id))
      channel = inbox.channel
      abort("Inbox #{inbox.id} is not a WhatsApp Cloud channel") unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
      unless channel.umi_foreign_owned?
        abort("Channel #{channel.id} is not marked foreign-owned. Set provider_config['umi_foreign_owned'] = true first.")
      end

      service = Whatsapp::WebhookSetupService.new(channel)

      puts "Channel #{channel.id} (inbox #{inbox.id}) #{channel.phone_number}"
      puts "  WABA:             #{channel.provider_config['business_account_id']}"
      puts "  Phone number ID:  #{channel.provider_config['phone_number_id']}"
      puts ''
      puts 'These two must already be saved and verified in this app\'s Meta dashboard'
      puts '(WhatsApp > Configuration > Webhook), with `messages` toggled to Subscribed:'
      puts "  Callback URL:     #{service.send(:build_callback_url)}"
      puts "  Verify token:     #{channel.provider_config['webhook_verify_token']}"
      puts ''

      begin
        service.register_callback
      rescue StandardError => e
        abort("FAILED: #{e.message}")
      end

      puts 'OK — app subscribed to the WABA and this app\'s callback override set.'
      puts "Verify with: GET /{phone-number-id}?fields=webhook_configuration using this channel's token."
    end
  end
end
