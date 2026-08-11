# frozen_string_literal: true

namespace :umi do
  namespace :meta do
    desc 'Create Meta ad attribution conversation attributes for an account with a Meta inbox'
    task :create_ad_attribute_definitions, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      definitions = Umi::Meta::AdAttributeDefinitionSetup.new(account).ensure_definitions!

      if definitions.empty?
        puts "Account #{account.id}: no Facebook Page or Instagram inbox; nothing to provision."
      else
        puts "Account #{account.id}: #{definitions.map(&:attribute_key).join(', ')} ready."
      end
    end
  end
end
