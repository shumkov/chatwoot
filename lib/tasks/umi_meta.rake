# frozen_string_literal: true

# Both provisioning tasks below report the same way, and inlining it twice puts
# the namespace block over the length limit.
def umi_report_definitions(account, definitions)
  if definitions.empty?
    puts "Account #{account.id}: no Facebook Page or Instagram inbox; nothing to provision."
  else
    puts "Account #{account.id}: #{definitions.map(&:attribute_key).join(', ')} ready."
  end
end

namespace :umi do
  namespace :meta do
    desc 'Create Meta ad attribution conversation attributes for an account with a Meta inbox'
    task :create_ad_attribute_definitions, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      umi_report_definitions(account, Umi::Meta::AdAttributeDefinitionSetup.new(account).ensure_definitions!)
    end

    desc 'Post the ad-context note on a conversation that carries Meta ad attribution'
    task :ad_context_note, [:conversation_id] => :environment do |_task, args|
      conversation = Conversation.find(args.fetch(:conversation_id))
      marker = Umi::Meta::AdContextNoteJob::MARKER

      # A failure note left by a transient Meta outage would otherwise block the
      # real one; clearing it here is what makes this task a recovery path.
      stale = conversation.messages.select { |m| m.content_attributes.dig(marker, 'status') == 'error' }
      Message.where(id: stale.map(&:id)).delete_all if stale.any?

      Umi::Meta::AdContextNoteJob.perform_now(conversation.id)
      posted = conversation.messages.reload.select { |m| m.content_attributes[marker].present? }
      puts "Conversation #{conversation.id}: #{posted.size} ad-context note(s), " \
           "status #{posted.map { |m| m.content_attributes.dig(marker, 'status') }.join(', ').presence || '-'}."
    end

    desc 'Create the Instagram profile contact attributes for an account with a Meta inbox'
    task :create_instagram_profile_definitions, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      umi_report_definitions(account, Umi::Meta::InstagramProfileAttributes.ensure_definitions!(account))
    end

    # The values have been arriving into additional_attributes for months on
    # hundreds of contacts; this copies them into the visible bucket. No Meta
    # call is made, so it costs nothing against the app quota that live message
    # delivery shares and can be run at any hour.
    desc 'Project stored Instagram profile fields onto contacts (DRY_RUN=true to count only)'
    task :project_instagram_profile_attributes, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      dry_run = ENV['DRY_RUN'] == 'true'
      counts = Umi::Meta::InstagramProfileAttributes.project_all!(account, dry_run: dry_run)

      puts "Account #{account.id}#{' (dry run)' if dry_run}: #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    end
  end
end
