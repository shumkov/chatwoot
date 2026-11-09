# frozen_string_literal: true

require 'rails_helper'

# These jobs run thousands of times an hour. Their arguments hold customer data and
# ActionCable pubsub tokens, which must not be copied into the job log, while each
# job's class and any failure must still be visible there.
RSpec.describe 'Job argument logging', type: :job do
  let(:secret) { 'umi-log-sentinel@example.com' }
  let(:log) { StringIO.new }

  around do |example|
    original = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::TaggedLogging.new(Logger.new(log))
    example.run
  ensure
    ActiveJob::Base.logger = original
  end

  {
    EventDispatcherJob => ->(secret) { EventDispatcherJob.perform_later('contact.updated', 1_700_000_000, { email: secret }) },
    ActionCableBroadcastJob => ->(secret) { ActionCableBroadcastJob.perform_later([secret], 'contact.updated', { email: secret }) },
    Umi::Funnel::CustomerProjectionJob => ->(secret) { Umi::Funnel::CustomerProjectionJob.perform_later(secret) },
    Umi::Funnel::ProfileSyncJob => ->(secret) { Umi::Funnel::ProfileSyncJob.perform_later(secret, force: true) }
  }.each do |job, enqueue|
    it "logs #{job.name} without its arguments" do
      enqueue.call(secret)

      expect(log.string).to include("Enqueued #{job.name}")
      expect(log.string).not_to include(secret)
    end
  end

  it 'still logs a failed broadcast with its error class' do
    expect do
      ActionCableBroadcastJob.perform_now([secret], 'conversation.updated', { account_id: 0, id: 1 })
    end.to raise_error(ActiveRecord::RecordNotFound)

    expect(log.string).to include('Error performing ActionCableBroadcastJob', 'ActiveRecord::RecordNotFound')
    expect(log.string).not_to include(secret)
  end
end
