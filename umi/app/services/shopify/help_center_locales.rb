# frozen_string_literal: true

# UMI patch: the one place that decides which Help Center locales sync and how.
#
# The source locale becomes a Shopify article. Every translation locale becomes a
# set of translations *on* that article (GraphQL `translationsRegister`), never a
# second article — see docs/UMI-HELP-CENTER-THAI-SPEC.md.
#
# The article model, the sync job and the rake tasks all read the policy here so
# a locale cannot be syncable in one of them and invisible to another.
module Umi::Shopify::HelpCenterLocales
  module_function

  def source
    ENV.fetch('UMI_HC_LOCALE', 'en')
  end

  # Setting UMI_HC_TRANSLATION_LOCALES to an empty string restores the
  # English-only behaviour this sync shipped with.
  def translations
    ENV.fetch('UMI_HC_TRANSLATION_LOCALES', 'th').split(',').map(&:strip).reject(&:blank?)
  end

  def source?(locale)
    locale.to_s == source
  end

  def translation?(locale)
    translations.include?(locale.to_s)
  end

  def syncable?(locale)
    source?(locale) || translation?(locale)
  end
end
