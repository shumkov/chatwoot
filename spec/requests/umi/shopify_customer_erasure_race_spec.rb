# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify customer confirmation during erasure', type: :request do
  self.use_transactional_tests = false

  # Keep both sessions and their synchronization visible in one concurrency example.
  # rubocop:disable RSpec/ExampleLength
  it 'does not retain identity fetched while customer erasure is being delivered' do
    account = create(:account)
    user = create(:user, account: account, role: :administrator)
    conversation = create(:conversation, account: account)
    conversation.contact.update!(email: nil, phone_number: nil)
    create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
    headers = user.create_new_auth_token
    url = "/api/v1/accounts/#{account.id}/umi/shopify/conversations/#{conversation.display_id}/customer"
    reader = instance_double(Umi::Shopify::CommerceReader)
    allow(Umi::Shopify::CommerceReader).to receive(:new).and_return(reader)
    read_started = Queue.new
    release_read = Queue.new
    allow(reader).to receive(:fetch).with('customer', '42') do
      read_started << true
      release_read.pop
      { 'id' => '42', 'name' => 'Erased customer' }
    end
    secret = 'local-race-webhook-secret'
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
    payload = { shop_domain: 'umi.myshopify.com', customer: { id: 42 }, orders_to_redact: [] }.to_json
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, payload))
    confirmation = ActionDispatch::Integration::Session.new(Rails.application)
    erasure = ActionDispatch::Integration::Session.new(Rails.application)
    confirming = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        confirmation.put url, params: { customer_id: '42' }, headers: headers, as: :json
      end
    end
    Timeout.timeout(10) { read_started.pop }
    erasure_pid = Queue.new
    erasing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        erasure_pid << connection.select_value('SELECT pg_backend_pid()')
        erasure.post '/webhooks/shopify', params: payload, headers: {
          'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => 'customers/redact',
          'X-Shopify-Hmac-SHA256' => signature, 'X-Shopify-Shop-Domain' => 'umi.myshopify.com'
        }
      end
    end
    pid = Timeout.timeout(10) { erasure_pid.pop }
    Timeout.timeout(10) do
      while erasing.alive?
        blocked = ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{pid.to_i}")
        break if blocked

        sleep 0.01
      end
    end
    release_read << true
    Timeout.timeout(10) { [confirming, erasing].each(&:value) }
    expect(confirmation.response.status).to eq(200)
    expect(erasure.response.status).to eq(200)
    attributes = conversation.contact.reload.additional_attributes
    expect(attributes['shopify_customer_id']).to be_nil
    expect(attributes['umi_profile_redacted']).to be(true)
  ensure
    release_read << true if release_read
    [confirming, erasing].compact.each { |thread| thread.join(10) }
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      account&.conversations&.destroy_all
      account&.contacts&.destroy_all
      account&.destroy!
    end
    user&.destroy!
  end
  # rubocop:enable RSpec/ExampleLength

  %i[confirmation erasure].each do |operation|
    it "allows paid-event inserts while #{operation} serializes customer identity" do
      account = create(:account)
      locked = Queue.new
      release = Queue.new
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          if operation == :confirmation
            Current.account = account
            controller = Umi::Shopify::CommerceController.new
            controller.send(:serialize_customer_identity) do
              locked << true
              release.pop
            end
          else
            controller = Webhooks::ShopifyController.new
            allow(controller).to receive(:compliance_account).and_return(account)
            allow(controller).to receive(:redact_customer_records) {
              locked << true
              release.pop
            }
            controller.send(:redact_customer)
          end
        ensure
          Current.reset
        end
      end
      Timeout.timeout(10) { locked.pop }
      expect do
        Umi::ConversationEvent.transaction do
          Umi::ConversationEvent.connection.execute("SET LOCAL lock_timeout = '100ms'")
          Umi::ConversationEvent.record!(account_id: account.id, event_type: 'order_paid', provenance: 'shopify',
                                         occurrence_key: 'concurrent-paid-order', observed_at: Time.current)
        end
      end.not_to raise_error
    ensure
      release << true if release
      worker&.join(10)
      Umi::ConversationEvent.where(account_id: account.id).destroy_all if account
      perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) { account&.destroy! }
    end
  end
  it 'completes erasure while a profile HTTP read waits and discards its late response' do
    account = create(:account)
    contact = create(:contact, account: account, email: 'erase@example.com', phone_number: nil,
                               additional_attributes: { 'shopify_customer_id' => '42', 'umi_klaviyo_profile_id' => 'P1',
                                                        'umi_klaviyo_binding' => { 'generation' => 'one' } })
    create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
    worker = nil
    reader = instance_double(Umi::Funnel::KlaviyoClient)
    started = Queue.new
    release = Queue.new
    allow(reader).to receive(:profile) do
      started << true
      release.pop
      { 'id' => 'P1', 'attributes' => { 'email' => 'erase@example.com', 'properties' => { 'umi_vip' => true } } }
    end
    expect(reader).not_to receive(:update_roles)
    secret = 'local-race-webhook-secret'
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
    payload = { shop_domain: 'umi.myshopify.com', customer: { id: 42 }, orders_to_redact: [] }.to_json
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, payload))
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { Umi::Funnel::CustomerContextSync.new(contact.id, client: reader).perform }
      end
      Timeout.timeout(10) { started.pop }
      Timeout.timeout(10) do
        post '/webhooks/shopify', params: payload, headers: {
          'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => 'customers/redact',
          'X-Shopify-Hmac-SHA256' => signature, 'X-Shopify-Shop-Domain' => 'umi.myshopify.com'
        }
      end
      expect(response).to have_http_status(:ok)
      release << true
      Timeout.timeout(10) { worker.value }
    end
    expect(Contact.exists?(contact.id)).to be(false)
  ensure
    release << true if release
    worker&.join(10)
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      account&.conversations&.destroy_all
      account&.contacts&.destroy_all
      account&.destroy!
    end
  end
end
