# frozen_string_literal: true

# Keeps Chatwoot's Liquid pass away from ad-context notes.
#
# Liquidable renders every outgoing message before it is created, private notes
# included, against contact/agent/conversation/inbox/account drops. An
# ad-context note is verbatim third-party text, and two things go wrong if it is
# rendered:
#
#   * Meta's greeting contains {{user_full_name}}, its own placeholder. Liquid
#     has no such drop, so it renders to nothing and the note becomes a
#     falsified record of what the customer was shown.
#   * Anything with edit access to the ad chooses that text. A literal
#     {% endraw %} in it would end an escaping wrapper early and let the rest be
#     evaluated, with {{contact.email}} and friends in scope.
#
# Escaping the text was tried and does not work: Liquidable rewrites backtick
# spans into raw blocks of its own, raw blocks do not nest, and the resulting
# SyntaxError is rescued — leaving literal {% raw %} markers in the note. Not
# rendering at all is the only version with no edge cases.
module Umi::AdContextNoteLiquidExempt
  private

  def liquid_processable_message?
    return false if content_attributes[Umi::Meta::AdContextNoteJob::MARKER].present?

    super
  end
end
