# frozen_string_literal: true

# UMI patch: the policy half of the Help Center translation sync — what a locale
# *should* hold for an article, and which of those fields may actually be
# written. No Shopify calls: the sync supplies the state, this decides.
#
# Kept apart from the sync so the dry-run report can ask the same question the
# pipe will answer without standing up the pipe, and so the rule can be read in
# one screen. Design: docs/UMI-HELP-CENTER-THAI-SPEC.md §4.1.
class Umi::Shopify::TranslationReconciler
  # Which Chatwoot field each key is *backed by* — the field an author edits to
  # change it. A backed key is one Chatwoot owns, so a Chatwoot edit is allowed to
  # replace what Shopify holds.
  #
  # `meta_title` is absent because Chatwoot has no SEO-title field — it is derived
  # from the article title — so whether it is backed depends on the locale's own
  # state rather than on a Chatwoot field. See #derived_meta_title?.
  # `summary_html` is backed only when the article has a description of its own;
  # otherwise it too is derived, from a truncation of the body.
  BACKING_FIELD = {
    'title' => :title,
    'body_html' => :content,
    'summary_html' => :description,
    'meta_description' => :description
  }.freeze

  META_DESCRIPTION_LIMIT = 320

  def initialize(title:, content:, description:)
    @title = title
    @content = content
    @description = description
  end

  # The translated values, keyed exactly as Shopify's translatable keys. Body and
  # summary go through the same helpers as the English article so the two
  # languages render identically on the same page.
  def values
    {
      'title' => Umi::Shopify::HelpCenterContent.single_line(@title),
      'body_html' => Umi::Shopify::HelpCenterContent.body_html(@content).presence,
      'summary_html' => Umi::Shopify::HelpCenterContent.summary_html(@description, @content).presence,
      'meta_title' => Umi::Shopify::HelpCenterContent.single_line(@title),
      'meta_description' => Umi::Shopify::HelpCenterContent.single_line(@description, limit: META_DESCRIPTION_LIMIT)
    }.compact
  end

  # Missing → translate. Outdated → replace. Matching → leave alone. Plus the one
  # clause that makes Chatwoot the source of truth rather than merely the storage:
  # a current field is rewritten when Chatwoot has a field behind it and that
  # field now says something else.
  #
  # `state` is everything the locale currently holds, keyed as `values` is,
  # because whether one key may be written can depend on another — see
  # #derived_meta_title?.
  def write?(key, value, state)
    current = state[key]
    # Blank counts as absent, not as a value to protect. Nothing in the live
    # corpus is blank (228/228 have content), but a field emptied by hand would
    # otherwise be unfillable forever: a blank `meta_title` can never equal its
    # title, so it would read as "phrased separately" and be skipped on every run.
    return true if current.nil? || current[:value].blank?
    return true if current[:outdated]

    backed?(key, state) && !same?(key, value, current[:value])
  end

  private

  def backed?(key, state)
    return derived_meta_title?(state) if key == 'meta_title'

    field = BACKING_FIELD[key]
    field.present? && chatwoot_fields[field].present?
  end

  def chatwoot_fields
    { title: @title, content: @content, description: @description }
  end

  # Chatwoot has no SEO-title field, so `meta_title` is ours to keep in step only
  # where nobody has said otherwise — and the locale itself says so: if its
  # `meta_title` still equals its `title`, the two were never pulled apart and a
  # title fix should carry. Where they differ, somebody phrased them separately
  # in Translate & Adapt, which presents them as two fields; that difference *is*
  # the intent, and a derived value must not overwrite it.
  def derived_meta_title?(state)
    title = state.dig('title', :value)
    title.present? && @title.present? && state.dig('meta_title', :value) == title
  end

  # HTML values are compared the way the importer compares them — entity spelling
  # and the trailing newline Shopify strips carry no meaning, a changed word does.
  def same?(key, value, current)
    if key.end_with?('_html')
      Umi::HelpCenter::HtmlToMarkdown.equivalent?(value, current)
    else
      value == current
    end
  end
end
