# frozen_string_literal: true

# Renders an ad's welcome message as the body of a private note.
#
# Only what the agent cannot already see goes in. The tap message already shows
# the option the customer chose word for word, and the conversation sidebar
# already shows the ad name and id, so neither is repeated. What is new is the
# greeting sent before the tap, the options not taken, and the answer the ad is
# configured to send — which on Messenger reaches the customer but never reaches
# Chatwoot, making this note the only record of it.
#
# No backticks anywhere in the output. Liquid is skipped for these notes
# (Umi::AdContextNoteLiquidExempt), but Chatwoot's Liquid pass rewrites backtick
# spans into raw blocks, and a stray one here would be a trap for anyone who
# later removes the exemption without noticing why it exists.
class Umi::Meta::AdContextNotePresenter
  def initialize(welcome, tapped_title: nil)
    @welcome = welcome
    @tapped_title = tapped_title
  end

  def body
    [greeting_part, choice_part, answer_part, hierarchy_part, footer].compact.join("\n\n")
  end

  # Written when Meta could not be read at all. It names no ad copy and gives
  # only the structured error fields, never an exception message, which can
  # carry the request URI and with it the page access token.
  def self.failure_body(reason)
    <<~NOTE.strip
      **Ad context unavailable.** Could not read this ad's welcome message from Meta (#{reason}).

      The customer may already have been answered by the ad. Check it in Ads Manager before replying.
    NOTE
  end

  private

  def greeting_part
    return if @welcome.greeting.blank?

    "**From the ad.** Before tapping, the customer was greeted with:\n#{quote(@welcome.greeting)}"
  end

  def choice_part
    return if titles.empty?
    return "The ad offered #{titles.size} options: #{italic_list(titles)}." if tapped_index.nil?

    others = titles.reject.with_index { |_, index| index == tapped_index }
    line = "They tapped **option #{tapped_index + 1} of #{titles.size}** — #{italic(titles[tapped_index])}."
    line += "\nThe other options were: #{italic_list(others)}." if others.any?
    line
  end

  def italic_list(names)
    names.map { |name| italic(name) }.join(', ')
  end

  # Every option on the current ad answers with the same text, so rendering it
  # once per option would be three copies of the same 300 characters. Saying so
  # is also the more useful fact: it means the answer did not address whichever
  # question was asked.
  def answer_part
    answers = @welcome.items.filter_map { |item| item[:response] }
    return if answers.empty?
    return per_option_answers if answers.uniq.size > 1

    "The ad is configured to answer#{identical_scope(answers)}:\n#{quote(answers.first)}"
  end

  def identical_scope(answers)
    answers.size > 1 ? " **all #{titles.size} options identically**, with" : ' with'
  end

  def per_option_answers
    lines = @welcome.items.filter_map do |item|
      next if item[:response].blank?

      "#{italic(item[:title])}\n#{quote(item[:response])}"
    end
    "The ad is configured to answer:\n\n#{lines.join("\n\n")}"
  end

  # Meta's webhook carries only the ad, so campaign and ad set are otherwise
  # invisible in Chatwoot. One line, and last: it is context for the answer
  # above it, not the thing the agent opened the conversation to read.
  #
  # Dropped entirely when neither level came back — the ad name on its own is
  # already in the conversation sidebar, so a line carrying just that is noise.
  def hierarchy_part
    levels = { 'Campaign' => @welcome.campaign_name, 'Ad set' => @welcome.adset_name }.compact_blank
    return if levels.empty?

    levels['Ad'] = @welcome.ad_name if @welcome.ad_name.present?
    levels.map { |label, name| "#{label}: #{italic(name)}" }.join(' › ')
  end

  def footer
    '_Read from Meta just now. Not visible to the customer. On Messenger the ad reply is not stored ' \
      'in Chatwoot, so this is the only record of it._'
  end

  def titles
    @titles ||= @welcome.items.pluck(:title)
  end

  # The option titles are exactly the text Meta sends as the customer's message
  # when the option is tapped, so an equality match identifies the choice.
  def tapped_index
    return @tapped_index if defined?(@tapped_index)

    @tapped_index = @tapped_title.present? ? titles.index(@tapped_title.strip) : nil
  end

  def quote(text)
    text.to_s.split("\n").map { |line| "> #{line}" }.join("\n")
  end

  def italic(text)
    "*#{text}*"
  end
end
