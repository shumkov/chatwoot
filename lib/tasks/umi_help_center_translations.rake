# frozen_string_literal: true

# UMI: the Help Center's non-English locales. They land on the *same* Shopify
# articles as translations rather than as articles of their own, so they have
# their own bootstrap, seed and status tasks — see docs/UMI-HELP-CENTER-THAI-SPEC.md.
# Helpers live in umi_help_center.rake, which Rake loads alongside this file.
#
#   bundle exec rake 'umi:help_center:import_translations[th]'         # report only
#   bundle exec rake 'umi:help_center:import_translations[th,apply]'   # write
#   bundle exec rake 'umi:help_center:backfill_translations[th]'
#   bundle exec rake 'umi:help_center:translation_status[th]'
#   bundle exec rake 'umi:help_center:translation_reviewed[th,7]'

namespace :umi do
  namespace :help_center do
    # Bootstrap for a locale whose translations were written straight into Shopify
    # before Chatwoot had a portal for it. Nothing is translated here — every value
    # comes from Shopify, and an article whose body cannot be proved to round-trip
    # is refused rather than guessed at.
    # The third argument stages the locale out of public view: the portal's
    # locale route answers 200 the moment articles exist under it.
    desc 'Import a locale\'s Shopify translations back into Chatwoot (dry run unless [locale,apply]; [locale,apply,draft] to stage)'
    task :import_translations, %i[locale apply status] => :environment do |_task, args|
      portal = umi_hc_portal
      locale = umi_hc_translation_locale(args[:locale])
      apply = args[:apply].to_s == 'apply'
      status = args[:status].presence || 'published'
      abort("Unknown status '#{status}' — use 'published' or 'draft'") unless %w[published draft].include?(status)
      result = Umi::HelpCenter::TranslationImportService.new(
        portal: portal, locale: locale, apply: apply, status: status
      ).perform

      puts "#{apply ? 'IMPORT (writing)' : 'DRY RUN'} — portal '#{portal.slug}', locale '#{locale}', status '#{status}'"
      puts result.report_lines(applied: apply)
      abort('Refusals present — nothing about them was written. Resolve them before trusting this import.') if result.refused?
    end
  end
end

namespace :umi do
  namespace :help_center do
    # Seed a locale's translations after an import. Runs the same job the article
    # hooks use, so there is one code path.
    desc 'Enqueue a Shopify translation sync for every published article in a locale'
    task :backfill_translations, [:locale] => :environment do |_task, args|
      portal = umi_hc_portal
      locale = umi_hc_translation_locale(args[:locale])
      articles = portal.articles.where(status: :published, locale: locale).where.not(associated_article_id: nil)
      count, spacing = umi_hc_enqueue_all(articles)

      puts "Enqueued #{count} '#{locale}' article(s) from portal '#{portal.slug}' " \
           "for Shopify translation sync, spaced #{spacing}s apart."
    end
  end
end

namespace :umi do
  namespace :help_center do
    # "I read the translation against the new English and it still says the right
    # thing." Saving an unchanged article in the dashboard does not clear the
    # drift flag, because Rails writes no row and so does not move updated_at —
    # without this there is no way to record a review that changed nothing, and
    # the flag would stay up forever on articles that are actually fine.
    desc 'Mark a translation as reviewed against its source (clears its drift flag)'
    task :translation_reviewed, %i[locale article_id] => :environment do |_task, args|
      portal = umi_hc_portal
      locale = umi_hc_translation_locale(args[:locale])
      abort('Pass the *source* article id, as shown by translation_status') if args[:article_id].blank?

      translation = portal.articles.find_by(associated_article_id: args[:article_id].to_i, locale: locale)
      abort("No '#{locale}' translation of article #{args[:article_id]} in portal '#{portal.slug}'") if translation.nil?

      # Moving updated_at without changing content is the whole point, so touch
      # is the right tool rather than a lint exception to work around.
      cleared = Umi::HelpCenter::TranslationReviewList.clear!(translation)
      translation.touch # rubocop:disable Rails/SkipsModelValidations
      puts "Marked '#{locale}' translation of article #{args[:article_id]} reviewed at #{translation.updated_at.iso8601}."
      puts "Cleared #{cleared} item(s) from the translator review list." if cleared.positive?
    end
  end
end

namespace :umi do
  namespace :help_center do
    # For the translator, not the operator. Lists the Thai the pipe wrote over
    # somebody else's Thai — which happens when English moved and the reconciler
    # re-derived the field — with both values readable and a link to the editor.
    # Cleared per article by `translation_reviewed`.
    desc 'List translations the sync replaced, for a translator to review'
    task :translation_review, [:locale] => :environment do |_task, args|
      portal = umi_hc_portal
      locale = umi_hc_translation_locale(args[:locale])
      list = Umi::HelpCenter::TranslationReviewList.new(portal: portal, locale: locale)

      puts "UMI Help Center — '#{locale}' translations waiting for review (#{list.entries.length})"
      puts
      puts list.report_lines
      puts "Sign off with: rake 'umi:help_center:translation_reviewed[#{locale},<article id>]'" if list.entries.any?
    end
  end
end

namespace :umi do
  namespace :help_center do
    # Which translations have fallen behind their source, and what the sync would
    # change in Shopify if it ran now. Exits non-zero when anything is behind, so
    # it can gate a deploy or drive a scheduled check.
    desc 'Report Help Center translations that are missing or behind their source article'
    task :translation_status, [:locale] => :environment do |_task, args|
      portal = umi_hc_portal
      locale = umi_hc_translation_locale(args[:locale])
      status = Umi::HelpCenter::TranslationStatusService.new(portal: portal, locale: locale)

      puts "Help Center translation status — portal '#{portal.slug}', locale '#{locale}'"
      puts status.report_lines
      abort('Translations are missing or behind their source.') if status.missing.any? || status.drifted.any?
    end
  end
end
