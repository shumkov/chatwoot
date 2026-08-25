# frozen_string_literal: true

# UMI patch: how a Chatwoot Help Center article's fields become Shopify values.
#
# Shared by the English article sync and the translation sync so the two cannot
# drift: a Thai body has to be rendered by the same markdown renderer and a Thai
# summary cut by the same rule, or the languages would render differently on the
# same page.
module Umi::Shopify::HelpCenterContent
  # Shopify rejects a `single_line_text_field` containing a line break with a 422 that
  # fails the *whole* article, so every value is squished to one line before it is sent.
  # `squish` (not `strip`) is required: it collapses U+2028 and non-breaking spaces,
  # which text pasted from a word processor carries and an ASCII-only `\s` would leave.
  # `limit` is applied after squishing, so a whitespace run straddling the cut cannot
  # move where it lands.
  SUMMARY_FALLBACK_LIMIT = 160

  module_function

  # Rendered with Chatwoot's own renderer so the storefront HTML matches the portal.
  def body_html(content)
    ChatwootMarkdownRenderer.new(content.to_s).render_article.to_s
  end

  # The article's own description when it has one; otherwise a plain-text cut of
  # the body. The cut is a known-rough fallback — see the truncation note in
  # docs/UMI-HELP-CENTER-THAI-SPEC.md §2.5.
  def summary_html(description, content)
    desc = description.to_s.strip
    return "<p>#{ERB::Util.html_escape(desc)}</p>" if desc.present?

    plain = ActionController::Base.helpers.strip_tags(content.to_s)
    plain = plain.gsub(/[#*_>`\[\]()]/, ' ').gsub(/\s+/, ' ').strip
    plain.present? ? "<p>#{ERB::Util.html_escape(plain[0, SUMMARY_FALLBACK_LIMIT])}</p>" : ''
  end

  def single_line(value, limit: nil)
    normalized = value.to_s.squish
    return nil if normalized.blank?

    limit ? normalized[0, limit] : normalized
  end
end
