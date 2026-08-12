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
  end
end
