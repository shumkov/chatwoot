# frozen_string_literal: true

# UMI patch: structured tracing for the FB / IG inbound message pipeline.
#
# Meta delivers each webhook once and the stock pipeline drops messages
# silently in several places (signature 400/401s, handover-protocol `standby`
# entries, unknown channels/pages, dedup and builder early-returns). Every
# decision point now emits one `[UMI-FBIG] stage=… key=value` line via
# Umi::FbigTrace, so a production drop leaves a diagnosable trail. Tracing
# never changes control flow (log-and-continue / log-and-reraise only) and can
# be silenced with UMI_FBIG_TRACE_DISABLED=true.
#
# remove-when: upstream adds equivalent observability to the Meta webhook
# pipeline (per-message persisted/dropped logging with reasons).

# The facebook-messenger gem's rack endpoint (mounted at /bot) — not a
# reloadable app class, so patch it once at boot. Three silent paths:
#   * signature failures answer 400 with no server-side log;
#   * `standby` entries (handover protocol: another app is the primary
#     receiver) are discarded before Chatwoot ever sees them;
#   * an unparseable/unknown payload raises out of the rack app as a 500,
#     failing the whole batch invisibly.
module Umi::FbigGemServerTrace
  def trigger(events)
    # Pre-super tracing is fully isolated: a trace bug must lose the trace
    # line, never turn a deliverable webhook into a 500.
    umi_trace_incoming(events)
    super
  rescue StandardError => e
    Umi::FbigTrace.log(:error, channel: 'facebook', reason: e.class.name, message: e.message)
    raise
  end

  def umi_trace_incoming(events)
    entries = events['entry'] || []
    Umi::FbigTrace.log(:webhook_received, channel: 'facebook', entries: entries.size,
                                          entry_ids: entries.filter_map { |entry| entry['id'] }.join(','))
    entries.each { |entry| umi_trace_standby_drop(entry) }
  rescue StandardError
    nil
  end

  def umi_trace_standby_drop(entry)
    return unless entry['standby'] && !entry['messaging']

    Umi::FbigTrace.log(:dropped, channel: 'facebook', reason: 'standby', entry_id: entry['id'],
                                 mids: entry['standby'].filter_map { |item| item.dig('message', 'mid') }.join(','))
  end

  def respond_with_error(error)
    Umi::FbigTrace.log(:rejected, channel: 'facebook', reason: 'signature', message: error.message)
    super
  end
end

Rails.application.config.after_initialize do
  if defined?(Facebook::Messenger::Server)
    methods_ok = Facebook::Messenger::Server.private_method_defined?(:trigger) &&
                 Facebook::Messenger::Server.private_method_defined?(:respond_with_error)
    raise 'UMI zz_umi_fbig_trace: Facebook::Messenger::Server#trigger/#respond_with_error no longer exist — rebase the patch.' unless methods_ok

    Facebook::Messenger::Server.prepend(Umi::FbigGemServerTrace) unless Facebook::Messenger::Server.include?(Umi::FbigGemServerTrace)
  end
end

Rails.application.reloader.to_prepare do
  {
    Webhooks::InstagramController => [Umi::FbigTrace::InstagramSignature, [:valid_meta_signature?]],
    Webhooks::InstagramEventsJob => [Umi::FbigTrace::InstagramJob, [:perform, :find_channel]],
    Webhooks::FacebookEventsJob => [Umi::FbigTrace::FacebookJob, [:perform]],
    Integrations::Facebook::MessageCreator => [Umi::FbigTrace::FacebookCreator, [:perform]],
    Messages::Facebook::MessageBuilder => [Umi::FbigTrace::FacebookBuilder, [:perform]],
    Messages::Instagram::BaseMessageBuilder => [Umi::FbigTrace::InstagramBuilder, [:perform, :message_already_exists?]]
  }.each do |klass, (mod, methods)|
    methods.each do |method|
      unless klass.method_defined?(method) || klass.private_method_defined?(method)
        raise "UMI zz_umi_fbig_trace: #{klass}##{method} no longer exists — rebase the patch."
      end
    end
    klass.prepend(mod) unless klass.include?(mod)
  end
end
