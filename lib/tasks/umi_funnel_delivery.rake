# frozen_string_literal: true

namespace :umi do
  namespace :funnel do
    desc 'Inspect or deliver an outcome (ACCOUNT_ID, DELIVERY_ID, ACTION=preview|dispatch|readback|hold)'
    task delivery: :environment do
      actions = { 'preview' => :prepare, 'dispatch' => :dispatch, 'readback' => :confirm, 'hold' => :hold_interrupted }
      action = actions.fetch(ENV.fetch('ACTION')) { raise ArgumentError, 'ACTION must be preview, dispatch, readback or hold' }
      account = Account.find(ENV.fetch('ACCOUNT_ID'))
      row = Umi::ConversionDelivery.joins(:conversation_event).where(umi_conversation_events: { account_id: account.id })
                                   .find(ENV.fetch('DELIVERY_ID'))
      Umi::Funnel::DeliveryService.new(row).public_send(action)
      row.reload
      puts JSON.generate(delivery_id: row.id, event_id: row.conversation_event_id, destination: row.destination,
                         state: row.state, reason: row.reason, attempt_count: row.attempt_count, last_error: row.last_error)
    end

    desc 'Bind a verified existing Klaviyo profile (ACCOUNT_ID, CONTACT_ID, PROFILE_ID, ACTOR_ID, REASON)'
    task bind_profile: :environment do
      account = Account.find(ENV.fetch('ACCOUNT_ID'))
      contact = account.contacts.find(ENV.fetch('CONTACT_ID'))
      Umi::Funnel::ProfileBinding.new(contact: contact, profile_id: ENV.fetch('PROFILE_ID'),
                                      actor: account.users.find(ENV.fetch('ACTOR_ID')), reason: ENV.fetch('REASON')).perform
      puts JSON.generate(contact_id: contact.id, profile_id: contact.additional_attributes.fetch('umi_klaviyo_profile_id'))
    end
  end
end
