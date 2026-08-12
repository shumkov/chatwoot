# frozen_string_literal: true

# Wires the ad-context note onto Meta ad attribution and onto Message.
#
# Inside to_prepare because umi/app is a reloadable autoload path: prepending at
# top level binds to the module object Zeitwerk hands out at boot, and after the
# first reload a fresh object with a clean singleton class takes its place and
# the prepend stops firing. Mirrors zz_umi_fbig_ad_attribution.rb.
Rails.application.reloader.to_prepare do
  # A prepend alone is not a loud failure. If a rebase renames or inlines
  # promote while the module survives, prepending would define a method nobody
  # calls and the notes would just stop, silently.
  %i[promote purge_for from_ads?].each do |method|
    next if Umi::FbigAdAttribution.respond_to?(method)

    raise "UMI zz_umi_meta_ad_context_note: Umi::FbigAdAttribution.#{method} no longer exists — rebase the patch."
  end

  unless Message.private_method_defined?(:liquid_processable_message?)
    raise 'UMI zz_umi_meta_ad_context_note: Liquidable#liquid_processable_message? no longer exists — rebase the patch.'
  end

  # module_function gives Umi::FbigAdAttribution both a private instance copy
  # and a singleton copy. Patch 20 calls it as Umi::FbigAdAttribution.promote,
  # which dispatches through the singleton class, so that is what to prepend to.
  unless Umi::FbigAdAttribution.singleton_class.include?(Umi::Meta::AdContextNoteTrigger)
    Umi::FbigAdAttribution.singleton_class.prepend(Umi::Meta::AdContextNoteTrigger)
  end

  Message.prepend(Umi::AdContextNoteLiquidExempt) unless Message.include?(Umi::AdContextNoteLiquidExempt)
end
