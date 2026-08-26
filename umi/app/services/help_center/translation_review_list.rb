# frozen_string_literal: true

# UMI patch: the Thai the pipe wrote over somebody's Thai, rendered for the
# person who has to check it.
#
# The reconciler replaces a translation when Shopify marks it outdated — English
# moved, so the Thai written against the old English is re-derived. That is
# correct and it is also the one case where a machine-authored string quietly
# supersedes a human-authored one, so it needs a human loop on the other side.
#
# The audience is a translator, not an operator. That decides the shape: the
# English title for orientation, both Thai values side by side with markup
# stripped so they can be read, and a URL that opens the article for editing.
# Anything she has to go hunting for will not get reviewed.
#
# Entries are stamped on the translation article by the sync
# (Umi::Shopify::ArticleTranslationSyncService) and cleared by
# `umi:help_center:translation_reviewed`.
class Umi::HelpCenter::TranslationReviewList
  META_KEY = 'translation_review'

  Entry = Struct.new(:article_id, :source_title, :key, :was, :now, :at, :url, keyword_init: true)

  def initialize(portal:, locale:)
    @portal = portal
    @locale = locale.to_s
  end

  def entries
    @entries ||= translations.flat_map { |article| entries_for(article) }
  end

  def report_lines
    return ['  nothing waiting for review.'] if entries.empty?

    entries.each_with_index.flat_map { |entry, index| lines_for(entry, index) }
  end

  # Called when somebody signs off on an article, so the list shrinks as it is
  # worked rather than growing until it is ignored.
  def self.clear!(article)
    meta = article.meta.is_a?(Hash) ? article.meta.dup : {}
    return 0 if Array(meta[META_KEY]).empty?

    count = Array(meta[META_KEY]).length
    meta.delete(META_KEY)
    # Not `update!`: clearing the list must not re-fire the sync, and must not
    # move updated_at, which is what the drift report reads.
    article.update_columns(meta: meta) # rubocop:disable Rails/SkipsModelValidations
    count
  end

  private

  attr_reader :portal, :locale

  def translations
    portal.articles.where(locale: locale).where.not(associated_article_id: nil).order(:id)
  end

  def entries_for(article)
    pending = article.meta.is_a?(Hash) ? Array(article.meta[META_KEY]) : []
    return [] if pending.empty?

    source_title = Article.find_by(id: article.associated_article_id)&.title
    pending.map do |item|
      Entry.new(article_id: article.associated_article_id, source_title: source_title,
                key: item['key'], was: readable(item['was']), now: readable(item['now']),
                at: item['at'], url: edit_url(article))
    end
  end

  # Body and summary values are HTML. A translator needs to read the sentence,
  # not the markup.
  def readable(value)
    ActionController::Base.helpers.strip_tags(value.to_s).squish
  end

  def edit_url(article)
    base = ENV.fetch('FRONTEND_URL', 'https://chat.umi.store').chomp('/')
    "#{base}/app/accounts/#{portal.account_id}/portals/#{portal.slug}/#{locale}/articles/edit/#{article.slug}"
  end

  def lines_for(entry, index)
    ["#{index + 1}. \"#{entry.source_title}\" · #{entry.key}",
     "     was: #{entry.was}",
     "     now: #{entry.now}",
     "    edit: #{entry.url}",
     '']
  end
end
