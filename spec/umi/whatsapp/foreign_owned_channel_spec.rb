require 'rails_helper'

# Guards for a WhatsApp Cloud channel on a number another platform provisioned and still
# owns. Every guard example is paired with the unguarded behaviour it diverges from, so a
# guard that stops working turns the pair red instead of leaving a passing snapshot.
#
# The division these tests defend (docs/UMI-SHARED-NUMBER-SPEC.md §1.2, §2.1): writes Meta
# scopes to the calling app are fine, writes scoped to the phone number are not.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'UMI foreign-owned WhatsApp channel' do
  let(:waba_id) { 'waba-owned-by-the-incumbent' }
  let(:phone_number_id) { 'pn-shared-number' }
  let(:base_config) do
    {
      'api_key' => 'chatwoot-token',
      'business_account_id' => waba_id,
      'phone_number_id' => phone_number_id,
      'webhook_verify_token' => 'chatwoot-verify-token',
      'source' => 'manual'
    }
  end
  let(:manual_channel) do
    build(:channel_whatsapp, phone_number: '+66975311301', provider: 'whatsapp_cloud', provider_config: base_config)
  end
  let(:foreign_channel) do
    build(:channel_whatsapp, phone_number: '+66975311302', provider: 'whatsapp_cloud',
                             provider_config: base_config.merge('umi_foreign_owned' => true))
  end

  before do
    # NOT_VERIFIED is the state that makes upstream register the number, so every example
    # below runs with the registration trigger pulled.
    stub_request(:get, /graph\.facebook\.com/).to_return(
      status: 200,
      body: { code_verification_status: 'NOT_VERIFIED', platform_type: 'CLOUD_API', throughput: { level: 'STANDARD' } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    stub_request(:post, /graph\.facebook\.com/).to_return(
      status: 200, body: { success: true }.to_json, headers: { 'Content-Type' => 'application/json' }
    )
  end

  describe 'the foreign-owned marker' do
    it 'is off unless a channel opts in, so an ordinary install is untouched' do
      expect(manual_channel.umi_foreign_owned?).to be false
    end

    it 'is off when the marker is explicitly false' do
      manual_channel.provider_config = base_config.merge('umi_foreign_owned' => false)

      expect(manual_channel.umi_foreign_owned?).to be false
    end

    it 'is on when a channel opts in' do
      expect(foreign_channel.umi_foreign_owned?).to be true
    end
  end

  describe 'Whatsapp::WebhookSetupService#perform' do
    it 'registers the phone number on an ordinary manual channel' do
      Whatsapp::WebhookSetupService.new(manual_channel).perform

      expect(a_request(:post, %r{graph\.facebook\.com/[^/]+/#{phone_number_id}/register})).to have_been_made
    end

    it 'never registers a foreign-owned number, because a PIN Chatwoot invented would replace the owner\'s two-step PIN' do
      Whatsapp::WebhookSetupService.new(foreign_channel).perform

      expect(a_request(:post, %r{graph\.facebook\.com/[^/]+/#{phone_number_id}/register})).not_to have_been_made
    end

    it 'stores a generated verification_pin on an ordinary manual channel' do
      Whatsapp::WebhookSetupService.new(manual_channel).perform

      expect(manual_channel.provider_config).to have_key('verification_pin')
    end

    it 'leaves no verification_pin behind, since that PIN belongs to the number owner and not to Chatwoot' do
      Whatsapp::WebhookSetupService.new(foreign_channel).perform

      expect(foreign_channel.provider_config).not_to have_key('verification_pin')
    end

    it 'subscribes this app to the WABA with exactly the fields Chatwoot consumes' do
      Whatsapp::WebhookSetupService.new(foreign_channel).perform

      expect(
        a_request(:post, %r{graph\.facebook\.com/[^/]+/#{waba_id}/subscribed_apps})
          .with(body: { subscribed_fields: %w[messages smb_message_echoes] }.to_json)
      ).to have_been_made.once
    end

    it 'sets its own phone-level callback override, which Meta keys per app so the incumbent\'s is untouched' do
      with_modified_env FRONTEND_URL: 'https://chat.example.com' do
        Whatsapp::WebhookSetupService.new(foreign_channel).perform
      end

      expect(
        a_request(:post, %r{graph\.facebook\.com/[^/]+/#{phone_number_id}\z})
          .with(body: { webhook_configuration: { override_callback_uri: 'https://chat.example.com/webhooks/whatsapp/+66975311302',
                                                 verify_token: 'chatwoot-verify-token' } }.to_json)
      ).to have_been_made.once
    end

    it 'writes nothing to Meta beyond those two app-scoped calls' do
      Whatsapp::WebhookSetupService.new(foreign_channel).perform

      expect(a_request(:post, /graph\.facebook\.com/)).to have_been_made.twice
    end
  end

  describe 'Whatsapp::WebhookSetupService#register_phone_number on a foreign-owned channel' do
    it 'raises instead of returning quietly, because its caller logs failures as "but continuing"' do
      service = Whatsapp::WebhookSetupService.new(foreign_channel)

      expect { service.send(:register_phone_number) }.to raise_error do |error|
        expect(error.class.name).to eq('Umi::Whatsapp::ForeignOwnedWebhookSetup::ForeignRegistrationAttempt')
      end
    end
  end

  describe 'the phone-override prerequisite Meta enforces' do
    before do
      stub_request(:post, %r{graph\.facebook\.com/[^/]+/#{phone_number_id}\z}).to_return(
        status: 400,
        body: { error: { message: '(#100) Before override the current callback uri, your app must be subscribed to receive ' \
                                  'messages for WhatsApp Business Account', code: 100 } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    end

    it 'fails loudly rather than leaving a channel that looks configured' do
      expect { Whatsapp::WebhookSetupService.new(foreign_channel).perform }.to raise_error(/Webhook setup failed/)
    end

    it 'leaves the error an ordinary channel raises exactly as upstream wrote it' do
      expect { Whatsapp::WebhookSetupService.new(manual_channel).register_callback }.to raise_error do |error|
        expect(error.message).to include('(#100) Before override the current callback uri')
        expect(error.message).not_to include('WhatsApp > Configuration > Webhook')
      end
    end

    it 'tells the operator to fix the app dashboard, not to re-subscribe the WABA the call just subscribed' do
      expect { Whatsapp::WebhookSetupService.new(foreign_channel).perform }.to raise_error do |error|
        expect(error.message).to include('(#100) Before override the current callback uri')
        expect(error.message).to include('WhatsApp > Configuration > Webhook')
        expect(error.message).to include('`messages` to Subscribed')
      end
    end
  end

  # The factory forces its own phone_number_id and business_account_id onto every created
  # channel, so persisted examples assert on the request body and method rather than on ids.
  describe 'channel creation' do
    it 'runs the full upstream setup, phone registration included, for an ordinary manual channel' do
      create(:channel_whatsapp, phone_number: '+66975311303', provider: 'whatsapp_cloud',
                                provider_config: base_config, sync_templates: false, validate_provider_config: false)

      expect(a_request(:post, %r{graph\.facebook\.com/[^/]+/[^/]+/register})).to have_been_made
    end

    it 'touches Meta not at all for a foreign-owned channel, because the callback URL and verify token it would ' \
       'publish only exist once the row is saved and the auto path reports failure as a log line' do
      create(:channel_whatsapp, phone_number: '+66975311304', provider: 'whatsapp_cloud',
                                provider_config: base_config.merge('umi_foreign_owned' => true),
                                sync_templates: false, validate_provider_config: false)

      expect(a_request(:post, /graph\.facebook\.com/)).not_to have_been_made
    end
  end

  describe 'channel deletion' do
    let(:persisted_foreign_channel) do
      create(:channel_whatsapp, phone_number: '+66975311305', provider: 'whatsapp_cloud',
                                provider_config: base_config.merge('umi_foreign_owned' => true),
                                sync_templates: false, validate_provider_config: false)
    end

    before do
      stub_request(:delete, /graph\.facebook\.com/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    end

    it 'clears its own callback override, which is Chatwoot\'s to remove and would otherwise be left on a number UMI does not own' do
      persisted_foreign_channel.destroy!

      expect(
        a_request(:post, /graph\.facebook\.com/)
          .with(body: { webhook_configuration: { override_callback_uri: '' } }.to_json)
      ).to have_been_made.once
    end

    it 'never unsubscribes the app from the WABA, which is shared with the incumbent' do
      persisted_foreign_channel.destroy!

      expect(a_request(:delete, %r{graph\.facebook\.com/[^/]+/[^/]+/subscribed_apps})).not_to have_been_made
    end
  end
end
# rubocop:enable RSpec/DescribeClass
