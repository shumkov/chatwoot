# frozen_string_literal: true

require 'rails_helper'

# The import that seeds a locale from Shopify has exactly one dangerous failure
# mode: silently changing somebody's translation. These pin the two properties
# that make that impossible — a construct it does not understand raises rather
# than being dropped, and everything it does understand survives a full trip
# through Chatwoot's own renderer unchanged.
RSpec.describe Umi::HelpCenter::HtmlToMarkdown do
  def round_trip(html)
    markdown = described_class.convert(html)
    ChatwootMarkdownRenderer.new(markdown).render_article.to_s
  end

  def expect_lossless(html)
    expect(described_class.equivalent?(round_trip(html), html))
      .to(be(true), "round trip changed the content\n  in:  #{html.inspect}\n  out: #{round_trip(html).inspect}")
  end

  describe '.convert' do
    it 'round-trips a paragraph with an inline link' do
      expect_lossless(%(<p>See our <a href="https://umi.store/pages/help">Help Center</a> for more.</p>\n))
    end

    it 'round-trips Thai prose, which carries no ASCII to anchor on' do
      expect_lossless(%(<p>หน้าผลิตภัณฑ์แต่ละหน้ามีตารางขนาดเป็นหน่วยเซนติเมตรและนิ้ว</p>\n))
    end

    it 'round-trips several paragraphs' do
      expect_lossless(%(<p>First.</p>\n<p>Second.</p>\n))
    end

    it 'round-trips emphasis' do
      expect_lossless(%(<p>Returns are <strong>free</strong> within <em>14 days</em>.</p>\n))
    end

    it 'round-trips a tight bullet list' do
      expect_lossless(%(<ul>\n<li>One</li>\n<li>Two</li>\n</ul>\n))
    end

    # CommonMark wraps a loose list's items in <p>, and only blank lines between
    # the markdown items reproduce that. Emitting a tight list here would rewrite
    # the article's HTML on the next sync for no reason.
    it 'round-trips a loose bullet list, whose items Shopify holds wrapped in <p>' do
      expect_lossless(%(<ul>\n<li>\n<p>Within 14 days of delivery</p>\n</li>\n<li>\n<p>Unworn, with tags attached</p>\n</li>\n</ul>\n))
    end

    it 'round-trips an ordered list' do
      expect_lossless(%(<ol>\n<li>One</li>\n<li>Two</li>\n</ol>\n))
    end

    # A URL carrying & and an apostrophe is the shape that broke the first
    # attempt at this — two of the live articles link to Google Maps that way.
    it 'round-trips a link whose URL carries ampersands and an apostrophe' do
      expect_lossless(
        %(<p>Visit <a href="https://maps.example/?api=1&amp;query=Tree%20O'clock%20Phuket">Tree O'Clock</a>.</p>\n)
      )
    end

    it 'escapes a paragraph that would otherwise open a markdown list' do
      expect_lossless(%(<p>- not a list item</p>\n))
    end

    it 'refuses an element it does not understand rather than dropping it' do
      expect { described_class.convert('<table><tr><td>x</td></tr></table>') }
        .to raise_error(described_class::UnsupportedNode, /table/)
    end

    it 'refuses an unknown inline element rather than keeping only its text' do
      expect { described_class.convert('<p>a <sup>b</sup></p>') }
        .to raise_error(described_class::UnsupportedNode, /sup/)
    end
  end

  describe '.equivalent?' do
    it 'ignores the trailing newline Shopify strips from stored values' do
      expect(described_class.equivalent?("<p>Hi</p>\n", '<p>Hi</p>')).to be(true)
    end

    # Two live articles were written by an older renderer that left an apostrophe
    # raw in an href where today's emits &#x27;. Identical in a browser, so the
    # comparison must not read it as a content change and refuse the import.
    it 'ignores entity spelling that decodes to the same character' do
      expect(described_class.equivalent?(%(<a href="/a?q=O&#x27;clock">x</a>), %(<a href="/a?q=O'clock">x</a>)))
        .to be(true)
    end

    it 'still catches a changed word' do
      expect(described_class.equivalent?('<p>free</p>', '<p>paid</p>')).to be(false)
    end

    it 'still catches a changed link target' do
      expect(described_class.equivalent?('<a href="/a">x</a>', '<a href="/b">x</a>')).to be(false)
    end

    it 'still catches a dropped element' do
      expect(described_class.equivalent?('<p>a</p>', "<p>a</p>\n<p>b</p>")).to be(false)
    end

    # This predicate decides whether the sync overwrites a translator's work, and
    # it was verified against a corpus of well-formed bodies. These are the inputs
    # the corpus does not contain. A false "same" hides a stale translation; a
    # false "different" overwrites a good one — both matter, so both directions
    # are pinned rather than just the happy path.
    describe 'inputs the real corpus does not contain' do
      it 'does not treat a numeric entity as different from the character' do
        expect(described_class.equivalent?('<p>&#3585;</p>', '<p>ก</p>')).to be(true)
      end

      it 'does not confuse a non-breaking space with a plain one' do
        expect(described_class.equivalent?('<p>a&nbsp;b</p>', '<p>a b</p>')).to be(false)
      end

      it 'sees through attribute order' do
        expect(described_class.equivalent?('<a href="/a" title="t">x</a>', '<a title="t" href="/a">x</a>'))
          .to be(false)
      end

      it 'does not silently drop an HTML comment' do
        expect(described_class.equivalent?('<p>a</p><!--note-->', '<p>a</p>')).to be(false)
      end

      it 'notices a script element rather than treating it as empty text' do
        expect(described_class.equivalent?('<p>a</p><script>x()</script>', '<p>a</p>')).to be(false)
      end

      it 'is not fooled by an unclosed tag that the parser repairs' do
        expect(described_class.equivalent?('<p>a', '<p>a</p>')).to be(true)
      end

      it 'treats an empty string and blank markup as different' do
        expect(described_class.equivalent?('', '<p></p>')).to be(false)
      end

      it 'compares nil as empty rather than raising' do
        expect(described_class.equivalent?(nil, '')).to be(true)
        expect(described_class.equivalent?(nil, '<p>a</p>')).to be(false)
      end
    end
  end
end
