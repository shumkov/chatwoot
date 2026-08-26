# frozen_string_literal: true

# UMI patch: turn Help Center article HTML back into the markdown Chatwoot stores.
#
# Used once, to import the Thai translations that were written straight into
# Shopify before Chatwoot had a Thai portal (docs/UMI-HELP-CENTER-THAI-SPEC.md §6).
# Chatwoot stores article bodies as markdown and renders them with
# ChatwootMarkdownRenderer; the import has only rendered HTML to work from.
#
# This is deliberately narrow. It covers exactly the constructs the corpus
# contains — paragraphs, links, bullet lists, bold, italic, line breaks — and
# raises on anything else, because the failure that matters is silently dropping
# a sentence of someone's translation. The caller re-renders the result and
# refuses any article that does not come back byte-identical, so this converter
# is checked rather than trusted.
module Umi::HelpCenter::HtmlToMarkdown
  class UnsupportedNode < StandardError; end

  # Markdown control characters that would change meaning if a translator's prose
  # happened to contain them. Parentheses and periods are safe inline and are left
  # alone so links and ordinary sentences are not littered with backslashes.
  INLINE_ESCAPES = /([\\`*_\[\]])/
  # At the start of a line these would open a list, heading or quote instead.
  LEADING_ESCAPES = /\A([-+>#]|\d+\.)/

  module_function

  # Whether two fragments say the same thing. Byte equality is too strict in two
  # ways that carry no meaning: the values in Shopify are stored without the
  # renderer's trailing newline, and some were written by an older renderer that
  # left an apostrophe raw in an href where today's emits `&#x27;`. Re-serialising
  # both through Nokogiri normalises entity spelling and nothing else — a changed
  # word, tag, or URL still fails.
  def equivalent?(left, right)
    canonical(left) == canonical(right)
  end

  def canonical(html)
    Nokogiri::HTML::DocumentFragment.parse(html.to_s).to_html.strip
  end

  def convert(html)
    fragment = Nokogiri::HTML::DocumentFragment.parse(html.to_s)
    blocks = fragment.children.filter_map { |node| block(node) }
    "#{blocks.join("\n\n")}\n"
  end

  def block(node)
    return nil if whitespace?(node)

    case node.name
    when 'p' then escape_leading(inline(node))
    when 'ul' then list(node, ordered: false)
    when 'ol' then list(node, ordered: true)
    when 'h1', 'h2', 'h3', 'h4', 'h5', 'h6' then "#{'#' * node.name[1].to_i} #{inline(node)}"
    when 'blockquote' then "> #{inline(node)}"
    else raise UnsupportedNode, "unsupported block element <#{node.name}>"
    end
  end

  # CommonMark wraps every item of a *loose* list in <p> and leaves a tight one
  # bare, and the two are only reproduced by blank lines between the markdown
  # items. Getting this backwards would rewrite the HTML on the next sync for no
  # reason, so the shape is read off the source rather than assumed.
  def list(node, ordered:)
    items = list_items(node)
    separator = items.any? { |item| item[:loose] } ? "\n\n" : "\n"
    items.each_with_index.map { |item, index| item(item[:paragraphs], ordered, index) }.join(separator)
  end

  def item(paragraphs, ordered, index)
    marker = ordered ? "#{index + 1}. " : '- '
    indent = ' ' * marker.length
    body = paragraphs.join("\n\n").gsub(/\n(?=[^\n])/, "\n#{indent}")
    "#{marker}#{body}"
  end

  def list_items(node)
    node.children.filter_map do |child|
      next nil if whitespace?(child)
      raise UnsupportedNode, "unsupported list child <#{child.name}>" unless child.name == 'li'

      list_item(child)
    end
  end

  def list_item(node)
    paragraphs = node.children.reject { |child| whitespace?(child) }
    return { loose: false, paragraphs: [inline(node)] } if paragraphs.none? { |child| child.name == 'p' }
    raise UnsupportedNode, 'list item mixes paragraphs with other blocks' unless paragraphs.all? { |c| c.name == 'p' }

    { loose: true, paragraphs: paragraphs.map { |child| inline(child) } }
  end

  def inline(node)
    node.children.map { |child| inline_node(child) }.join
  end

  def inline_node(node)
    case node.name
    when 'text' then node.text.gsub(INLINE_ESCAPES, '\\\\\1')
    when 'a' then "[#{inline(node)}](#{node['href']})"
    when 'strong', 'b' then "**#{inline(node)}**"
    when 'em', 'i' then "*#{inline(node)}*"
    when 'code' then "`#{node.text}`"
    when 'br' then "  \n"
    else raise UnsupportedNode, "unsupported inline element <#{node.name}>"
    end
  end

  def escape_leading(text)
    text.sub(LEADING_ESCAPES) { |match| "\\#{match}" }
  end

  def whitespace?(node)
    node.text? && node.text.strip.empty?
  end
end
