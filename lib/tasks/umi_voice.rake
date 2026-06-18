# frozen_string_literal: true

namespace :umi do
  namespace :voice do
    desc 'Create the "Call" tap-to-call link contact attribute for an account'
    task :create_call_attribute, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      definition = Umi::Voice::CallLinkSetup.new(account).ensure_definition!
      puts "Account #{account.id}: contact attribute '#{definition.attribute_key}' (#{definition.attribute_display_type}) ready."
    end

    desc 'Backfill each contact (with a phone) with its signed tap-to-call link for an account'
    task :backfill_call_links, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      count = Umi::Voice::CallLinkSetup.new(account).backfill_contacts!
      puts "Account #{account.id}: #{count} contacts updated with a tap-to-call link."
    end

    desc 'Create the "Call contact" macro (tap it in any app to ring the assignee + dial the contact)'
    task :create_call_macro, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      user = account.users.first
      macro = account.macros.find_or_initialize_by(name: '📞 Call contact')
      macro.update!(visibility: :global, created_by: user, updated_by: user,
                    actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => [Umi::Voice.macro_dial_url] }])
      puts "Account #{account.id}: macro '#{macro.name}' (##{macro.id}) -> #{Umi::Voice.macro_dial_url}"
    end
  end
end
