# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ContactSyncService do
  let(:account) { create(:account) }

  def customer(id:, **overrides)
    {
      'id' => id, 'email' => nil, 'phone' => nil,
      'first_name' => 'Somchai', 'last_name' => nil,
      'orders_count' => 1, 'total_spent' => '10.00', 'currency' => 'THB',
      'updated_at' => '2026-07-01T10:00:00Z'
    }.merge(overrides.transform_keys(&:to_s))
  end

  def sync(customers, mode: :bulk)
    described_class.new(account: account, customers: customers, mode: mode).perform
  end

  describe 'creation' do
    it 'creates contacts with type customer and denormalized location (bulk import skips callbacks)' do
      counters = sync([customer(id: 1, email: 'a@example.com',
                                default_address: { 'city' => 'Bangkok', 'country_code' => 'TH' })])

      contact = account.contacts.from_email('a@example.com')
      expect(counters[:created]).to eq(1)
      expect(contact.contact_type).to eq('customer')
      expect(contact.location).to eq('Bangkok')
      expect(contact.country_code).to eq('TH')
      expect(contact.additional_attributes['shopify_customer_id']).to eq(1)
    end

    it 'creates via Contact.import in bulk mode and create! in per_record mode' do
      expect(Contact).to receive(:import).and_call_original
      sync([customer(id: 1, email: 'bulk@example.com')])
      expect(account.contacts.from_email('bulk@example.com')).to be_present

      expect(Contact).not_to receive(:import)
      sync([customer(id: 2, email: 'poll@example.com')], mode: :per_record)
      expect(account.contacts.from_email('poll@example.com')).to be_present
    end

    it 'counts skipped customers with no usable identity' do
      counters = sync([customer(id: 1)])

      expect(counters[:skipped_no_identity]).to eq(1)
      expect(account.contacts.count).to eq(0)
    end
  end

  describe 'in-batch dedup (no unique phone index exists — dedup is application-level)' do
    it 'gives a shared phone to the most recently updated customer' do
      counters = sync([
                        customer(id: 1, phone: '+66811111111', email: 'old@example.com', updated_at: '2026-01-01T00:00:00Z'),
                        customer(id: 2, phone: '+66811111111', email: 'new@example.com', updated_at: '2026-07-01T00:00:00Z')
                      ])

      expect(counters[:deduped]).to eq(1)
      expect(account.contacts.from_email('new@example.com').phone_number).to eq('+66811111111')
      expect(account.contacts.from_email('old@example.com').phone_number).to be_nil
    end

    it 'drops a row entirely when dedup strips its only key' do
      sync([
             customer(id: 1, phone: '+66811111111', updated_at: '2026-07-01T00:00:00Z'),
             customer(id: 2, phone: '+66811111111', updated_at: '2026-01-01T00:00:00Z')
           ])

      expect(account.contacts.count).to eq(1)
      expect(account.contacts.first.additional_attributes['shopify_customer_id']).to eq(1)
    end
  end

  describe 'enrichment of existing contacts' do
    it 'fills blanks without overwriting agent-entered data and links the customer id' do
      contact = create(:contact, account: account, name: 'Agent Entered', email: 'a@example.com', phone_number: nil)

      counters = sync([customer(id: 7, email: 'a@example.com', phone: '+66812345678', first_name: 'Shopify')])

      contact.reload
      expect(counters[:enriched]).to eq(1)
      expect(contact.name).to eq('Agent Entered')
      expect(contact.phone_number).to eq('+66812345678')
      expect(contact.additional_attributes['shopify_customer_id']).to eq(7)
      expect(contact.contact_type).to eq('customer')
    end

    it 'upgrades placeholder names (phone number, email local part, haikunator)' do
      by_phone = create(:contact, account: account, name: '+66811111111', phone_number: '+66811111111')
      by_local = create(:contact, account: account, name: 'somchai', email: 'somchai@example.com')
      by_haiku = create(:contact, account: account, name: 'wispy-dust-1234', email: 'h@example.com')

      sync([
             customer(id: 1, phone: '+66811111111', first_name: 'Real', last_name: 'Caller'),
             customer(id: 2, email: 'somchai@example.com', first_name: 'Somchai', last_name: 'P'),
             customer(id: 3, email: 'h@example.com', first_name: 'Real', last_name: 'Name')
           ])

      expect(by_phone.reload.name).to eq('Real Caller')
      expect(by_local.reload.name).to eq('Somchai P')
      expect(by_haiku.reload.name).to eq('Real Name')
    end

    # Two Shopify customers sharing a phone must not flap the contact's linked
    # identity between runs — and redact must never hit the wrong person.
    it 'never overwrites a different existing shopify_customer_id (conflicted)' do
      contact = create(:contact, account: account, phone_number: '+66811111111',
                                 additional_attributes: { 'shopify_customer_id' => 111, 'shopify_orders_count' => 9 })

      counters = sync([customer(id: 222, phone: '+66811111111', first_name: 'Other')])

      expect(counters[:conflicted]).to eq(1)
      expect(contact.reload.additional_attributes['shopify_customer_id']).to eq(111)
      expect(contact.additional_attributes['shopify_orders_count']).to eq(9)
    end

    it 'is idempotent: a second identical run saves nothing (unchanged, no update events)' do
      customers = [customer(id: 1, email: 'a@example.com', phone: '+66812345678',
                            default_address: { 'city' => 'Bangkok', 'country_code' => 'TH' })]
      sync(customers)

      contact = account.contacts.from_email('a@example.com')
      first_run_updated_at = contact.updated_at
      counters = sync(customers)

      expect(counters[:unchanged]).to eq(1)
      expect(counters[:enriched]).to eq(0)
      expect(contact.reload.updated_at).to eq(first_run_updated_at)
    end

    # Split identity: the customer's email matched contact A but the phone
    # already belongs to contact B — filling A would duplicate the phone across
    # contacts (no unique index) and break caller-ID resolution.
    it 'does not fill a phone that already belongs to a different contact' do
      by_email = create(:contact, account: account, email: 'a@example.com', phone_number: nil)
      by_phone = create(:contact, account: account, phone_number: '+66812345678', email: nil)

      sync([customer(id: 7, email: 'a@example.com', phone: '+66812345678')])

      expect(by_email.reload.phone_number).to be_nil
      expect(by_phone.reload.phone_number).to eq('+66812345678')
    end

    it 'clears sync-owned keys removed in Shopify (stale tags/consent)' do
      contact = create(:contact, account: account, email: 'a@example.com',
                                 additional_attributes: { 'shopify_customer_id' => 5, 'shopify_tags' => 'vip' })

      sync([customer(id: 5, email: 'a@example.com', tags: '')])

      expect(contact.reload.additional_attributes).not_to have_key('shopify_tags')
    end

    it 'treats a full-email display name as a placeholder' do
      contact = create(:contact, account: account, name: 'somchai@example.com', email: 'somchai@example.com')

      sync([customer(id: 8, email: 'somchai@example.com', first_name: 'Somchai', last_name: 'P')])

      expect(contact.reload.name).to eq('Somchai P')
    end

    it 'preserves foreign additional_attributes keys on merge' do
      contact = create(:contact, account: account, email: 'a@example.com',
                                 additional_attributes: { 'company_name' => 'ACME' })

      sync([customer(id: 5, email: 'a@example.com')])

      expect(contact.reload.additional_attributes['company_name']).to eq('ACME')
      expect(contact.additional_attributes['shopify_customer_id']).to eq(5)
    end
  end
end
