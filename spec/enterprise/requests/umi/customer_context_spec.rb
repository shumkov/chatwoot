# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise customer context writes', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, custom_attributes: { umi_vip: 'no', umi_wholesale: 'yes' }) }
  let(:path) { "/api/v1/accounts/#{account.id}/contacts/#{contact.id}" }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
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
end
