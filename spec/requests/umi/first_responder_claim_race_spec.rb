# frozen_string_literal: true

require 'rails_helper'

# Two people answering the same unassigned conversation at once must end with
# one owner. Both replies exist before either claim takes the row lock: the
# claim that takes the lock first wins, and the other re-reads the conversation
# under the lock, sees that owner and leaves it. Both replies are kept.
RSpec.describe 'First responder claim under simultaneous replies', type: :request do
  self.use_transactional_tests = false

  # Keep both sessions and their synchronization visible in one example.
  # rubocop:disable RSpec/ExampleLength
  it 'gives the conversation to the first successful claim and keeps both replies' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    ivan = create(:user, account: account, role: :administrator, name: 'Ivan')
    dina = create(:user, account: account, role: :agent, name: 'Dina')
    [ivan, dina].each { |user| create(:inbox_member, inbox: inbox, user: user) }
    settings = InstallationConfig.create!(name: 'UMI_FIRST_RESPONDER_CLAIM', value: { 'inbox_ids' => [inbox.id] })
    conversation = create(:conversation, account: account, inbox: inbox)
    path = "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages"
    sessions = [ivan, dina].map do |user|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
      [session, session.response.headers.slice('access-token', 'client', 'uid')]
    end
    arrived = Queue.new
    proceed = Queue.new
    holding = Queue.new
    release = Queue.new
    # Gate only the claim's own lock: the waiter stops before taking it, the
    # holder keeps it while the waiter queues behind it.
    allow_any_instance_of(Conversation).to receive(:with_lock).and_wrap_original do |original, *args, &block| # rubocop:disable RSpec/AnyInstance
      case args == ['FOR NO KEY UPDATE'] && Thread.current[:umi_claim_role]
      when :waiter
        arrived << true
        proceed.pop
        original.call(*args, &block)
      when :holder
        original.call(*args) do
          holding << true
          release.pop
          block.call
        end
      else
        original.call(*args, &block)
      end
    end

    waiter_pid = Queue.new
    waiter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:umi_claim_role] = :waiter
        waiter_pid << connection.select_value('SELECT pg_backend_pid()')
        session, headers = sessions.last
        session.post path, params: { content: 'We have it in M.' }, headers: headers, as: :json
      end
    end
    Timeout.timeout(10) { arrived.pop }
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:umi_claim_role] = :holder
        session, headers = sessions.first
        session.post path, params: { content: 'Size M is in stock.' }, headers: headers, as: :json
      end
    end
    Timeout.timeout(10) { holding.pop }
    proceed << true
    pid = Timeout.timeout(10) { waiter_pid.pop }
    Timeout.timeout(10) do
      until ActiveRecord::Base.connection.select_value(
        "SELECT wait_event_type = 'Lock' AND query ILIKE '%FOR NO KEY UPDATE%' FROM pg_stat_activity WHERE pid = #{pid.to_i}"
      )
        raise 'the later claim finished without queueing behind the claim lock' unless waiter.alive?

        sleep 0.01
      end
    end
    release << true
    Timeout.timeout(10) { [holder, waiter].each(&:value) }

    expect(sessions.map { |session, _| session.response.status }).to eq([200, 200])
    expect(conversation.reload.assignee).to eq(ivan)
    expect(conversation.messages.outgoing.pluck(:content)).to contain_exactly('Size M is in stock.', 'We have it in M.')
    activities = enqueued_jobs.select { |job| job[:job] == Conversations::ActivityMessageJob }
    expect(activities.map { |job| job[:args].last['content'] }).to eq(['Ivan self-assigned this conversation'])
  ensure
    proceed << true if proceed
    release << true if release
    [holder, waiter].compact.each do |thread|
      thread.join(10)
    rescue StandardError
      # A failed thread has already failed the example; the cleanup must still run.
      next
    end
    settings&.destroy!
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      account&.conversations&.destroy_all
      account&.contacts&.destroy_all
      account&.destroy!
    end
    [ivan, dina].compact.each(&:destroy!)
  end
  # rubocop:enable RSpec/ExampleLength
end
