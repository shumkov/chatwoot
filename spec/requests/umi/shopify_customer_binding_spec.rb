# frozen_string_literal: true

require 'rails_helper'

# Generic contact writers merge caller-supplied additional_attributes, so they
# can set shopify_customer_id too. One Shopify customer stays on at most one
# contact: agents get the same refusal as the commerce panel, and website
# visitors cannot claim a Shopify customer at all.
RSpec.describe 'Shopify customer binding through generic contact writers', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account, name: 'Before', additional_attributes: { 'company_name' => 'ACME' }) }
  let(:path) { "/api/v1/accounts/#{account.id}/contacts/#{contact.id}" }

  describe 'agent contacts API' do
    it 'refuses to bind a customer another contact carries, with no write at all' do
      create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 42 })

      patch path, headers: admin.create_new_auth_token, as: :json,
                  params: { name: 'After', additional_attributes: { shopify_customer_id: '42' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'customer_bound_elsewhere')
      expect(contact.reload.name).to eq('Before')
      expect(contact.additional_attributes).to eq('company_name' => 'ACME')
    end

    it 'binds a customer no other contact carries' do
      patch path, headers: admin.create_new_auth_token, as: :json, params: { additional_attributes: { shopify_customer_id: '42' } }

      expect(response).to have_http_status(:success)
      expect(contact.reload.additional_attributes).to eq('company_name' => 'ACME', 'shopify_customer_id' => '42')
    end

    it 'refuses to create a second contact for a bound customer' do
      create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => '42' })

      expect do
        post "/api/v1/accounts/#{account.id}/contacts", headers: admin.create_new_auth_token, as: :json,
                                                        params: { name: 'Copy', additional_attributes: { shopify_customer_id: 42 } }
      end.not_to change(Contact, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'customer_bound_elsewhere')
    end

    # The historical pairs are left alone: editing either member, even
    # resending its own customer id, works exactly as before.
    it 'keeps editing members of an existing duplicate pair' do
      contact.update!(additional_attributes: { 'shopify_customer_id' => '42' })
      create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 42 })

      patch path, headers: admin.create_new_auth_token, as: :json, params: { name: 'Renamed' }
      expect(response).to have_http_status(:success)
      patch path, headers: admin.create_new_auth_token, as: :json,
                  params: { name: 'Again', additional_attributes: { shopify_customer_id: '42', company_name: 'UMI' } }
      expect(response).to have_http_status(:success)

      expect(contact.reload.name).to eq('Again')
      expect(contact.additional_attributes).to eq('shopify_customer_id' => '42', 'company_name' => 'UMI')
    end

    it 'refuses with no write when the customer context wraps the update' do
      create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 42 })

      with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        patch path, headers: admin.create_new_auth_token, as: :json,
                    params: { name: 'After', additional_attributes: { shopify_customer_id: '42' } }
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'customer_bound_elsewhere')
      expect(contact.reload.name).to eq('Before')
      expect(contact.additional_attributes).to eq('company_name' => 'ACME')
    end

    # The customer context wrapper renders its own validation errors; the
    # request must still write nothing, not keep a contact bound to the id.
    it 'writes nothing when the customer context rejects a create that names a free customer' do
      with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        expect do
          post "/api/v1/accounts/#{account.id}/contacts", headers: admin.create_new_auth_token, as: :json,
                                                          params: { name: 'New', additional_attributes: { shopify_customer_id: '55' },
                                                                    custom_attributes: { umi_vip: 'maybe' } }
        end.not_to change(Contact, :count)
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'Role must be unknown, yes or no')
    end
  end

  describe 'website widget' do
    let(:web_widget) { create(:channel_widget, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: web_widget.inbox) }
    let(:token) { Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: web_widget.inbox.id }).generate_token }

    it 'never lets a visitor claim a Shopify customer, and keeps what the contact already carries' do
      contact.update!(additional_attributes: { 'company_name' => 'ACME', 'shopify_orders_count' => 3 })

      patch '/api/v1/widget/contact', headers: { 'X-Auth-Token' => token }, as: :json,
                                      params: { website_token: web_widget.website_token,
                                                additional_attributes: { shopify_customer_id: 42, shopify_tags: 'vip', shopify_orders_count: 99,
                                                                         description: 'from widget' } }

      expect(response).to have_http_status(:success)
      expect(contact.reload.additional_attributes).to eq('company_name' => 'ACME', 'shopify_orders_count' => 3,
                                                         'description' => 'from widget')
    end

    # A visitor who submits someone else's email is merged into that contact.
    # Marking that contact erased would keep its Shopify customer from ever
    # being bound again, so visitor input carrying UMI technical keys is
    # refused outright (Umi::Funnel::CustomerBoundary), whatever else it sets.
    %w[umi_profile_redacted umi_klaviyo_profile_id umi_klaviyo_binding umi_klaviyo_sync umi_customer_projection].each do |key|
      it "refuses visitor input carrying #{key}" do
        contact.update!(additional_attributes: { 'company_name' => 'ACME', 'umi_klaviyo_profile_id' => 'kl-1' })

        patch '/api/v1/widget/contact', headers: { 'X-Auth-Token' => token }, as: :json,
                                        params: { website_token: web_widget.website_token,
                                                  additional_attributes: { key => 'visitor', 'description' => 'from widget' } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(contact.reload.additional_attributes).to eq('company_name' => 'ACME', 'umi_klaviyo_profile_id' => 'kl-1')
      end
    end
  end

  # A merge is not a second binding: the base inherits the mergee's customer
  # while the mergee is deleted in the same commit.
  describe 'contact merge' do
    it 'moves the binding onto the base without a second carrier' do
      mergee = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => '42', 'shopify_tags' => 'vip' })

      ContactMergeAction.new(account: account, base_contact: contact, mergee_contact: mergee).perform

      bound = Contact.where(account_id: account.id).where("additional_attributes ->> 'shopify_customer_id' = '42'").pluck(:id)
      expect(bound).to eq([contact.id])
      expect(contact.reload.additional_attributes).to include('company_name' => 'ACME', 'shopify_tags' => 'vip')
    end
  end
end
