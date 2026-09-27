# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rake::Task do
  subject(:task) { described_class['umi:funnel:cohorts'] }

  before { task.reenable }

  it 'prints one completed cohort JSON report using explicit time and horizon arguments' do
    allow(Umi::Funnel::CohortReport).to receive(:perform).with(account_id: '1', from: '2026-09-01T00:00:00Z',
                                                               until_time: '2026-09-08T00:00:00Z', as_of: '2026-09-22T00:00:00Z',
                                                               horizon_days: '14').and_return(schema_version: 1, rows: [])
    with_modified_env ACCOUNT_ID: '1', FROM: '2026-09-01T00:00:00Z', UNTIL: '2026-09-08T00:00:00Z',
                      AS_OF: '2026-09-22T00:00:00Z', HORIZON_DAYS: '14' do
      expect { task.invoke }.to output("{\"schema_version\":1,\"rows\":[]}\n").to_stdout
    end
  end

  it 'prints no completed report when an explicit required argument is absent' do
    with_modified_env ACCOUNT_ID: nil do
      expect { expect { task.invoke }.to raise_error(KeyError) }.not_to output.to_stdout
    end
  end
end
