# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer context writes', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, custom_attributes: { umi_vip: 'no', umi_wholesale: 'yes' }) }
  let(:path) { "/api/v1/accounts/#{account.id}/contacts/#{contact.id}" }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'merges a single role edit with the current roles and records pending intent' do
    patch path, headers: agent.create_new_auth_token, params: { custom_attributes: { umi_vip: 'yes' } }, as: :json
    expect(response).to have_http_status(:success)
    expect(contact.reload.custom_attributes).to include('umi_vip' => 'yes', 'umi_wholesale' => 'yes')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('yes')
  end

  it 'rejects forging derived purchase fields and keeps unrelated edits atomic' do
    patch path, headers: agent.create_new_auth_token,
                params: { name: 'Wrong', custom_attributes: { umi_paid_order_count: 12 } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(contact.reload.name).not_to eq('Wrong')
  end

  it 'retains Enterprise company assignment when updating a customer role' do
    account.enable_features!(:companies)
    company = create(:company, account: account)
    patch path, headers: agent.create_new_auth_token,
                params: { company_id: company.id, custom_attributes: { umi_vip: 'yes' } }, as: :json
    expect(response).to have_http_status(:success)
    expect(contact.reload.company_id).to eq(company.id)
    expect(contact.custom_attributes['umi_vip']).to eq('yes')
  end

  it 'records no and unknown as distinct operator choices and rejects deleting payment history' do
    %w[yes no unknown].each do |value|
      patch path, headers: agent.create_new_auth_token, params: { custom_attributes: { umi_vip: value } }, as: :json
      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes['umi_vip']).to eq(value)
    end
    post "#{path}/destroy_custom_attributes", headers: agent.create_new_auth_token,
                                              params: { custom_attributes: ['umi_paid_order_count'] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
