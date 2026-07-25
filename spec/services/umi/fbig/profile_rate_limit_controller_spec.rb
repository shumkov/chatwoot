require 'rails_helper'

RSpec.describe Umi::Fbig::ProfileRateLimitController do
  let(:sleeper) { instance_double(Proc, call: nil) }
  let(:renewer) { instance_double(Proc, call: true) }

  it 'renews before the fixed preventive wait when usage reaches the threshold' do
    controller = described_class.new(max_wait_seconds: 180, sleeper: sleeper, renewer: renewer)
    controller.observe(
      Umi::Fbig::SanitizedKoalaApi::Usage.new(maximum_percent: 85, estimated_regain_minutes: 2)
    )

    controller.before_request!

    expect(renewer).to have_received(:call).once
    expect(sleeper).to have_received(:call).with(60).once
    expect(controller.waited_seconds).to eq(60)
  end

  it 'uses a server regain estimate plus bounded jitter instead of the fallback and does not wait twice' do
    random = instance_double(Random, rand: 3)
    controller = described_class.new(
      max_wait_seconds: 180,
      sleeper: sleeper,
      renewer: renewer,
      random: random
    )
    controller.observe(
      Umi::Fbig::SanitizedKoalaApi::Usage.new(maximum_percent: 85, estimated_regain_minutes: 2)
    )

    controller.retry_wait!(1)
    controller.before_request!

    expect(renewer).to have_received(:call).exactly(3).times
    expect(sleeper).to have_received(:call).with(60).twice
    expect(sleeper).to have_received(:call).with(3).once
    expect(controller.waited_seconds).to eq(123)
  end

  it 'uses the bounded retry schedule and stops before exceeding the wait budget' do
    controller = described_class.new(max_wait_seconds: 359, sleeper: sleeper, renewer: renewer)

    controller.retry_wait!(1)
    expect { controller.retry_wait!(2) }.to raise_error(described_class::WaitBudgetError)

    expect(sleeper).to have_received(:call).with(60).once
    expect(controller.waited_seconds).to eq(60)
  end

  it 'does not sleep when lease renewal fails' do
    allow(renewer).to receive(:call).and_return(false)
    controller = described_class.new(max_wait_seconds: 60, sleeper: sleeper, renewer: renewer)

    expect { controller.retry_wait!(1) }.to raise_error(described_class::LockLossError)
    expect(sleeper).not_to have_received(:call)
  end
end
