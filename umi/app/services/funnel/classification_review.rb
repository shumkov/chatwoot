# frozen_string_literal: true

class Umi::Funnel::ClassificationReview
  def self.export(account_id:, manifest:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
    samples = manifest.fetch('samples')
    ids = samples.map { |sample| sample.fetch('sample') }
    raise ArgumentError, 'Sample IDs must be unique positive integers' unless ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq == ids

    config = Umi::Funnel::ClassificationClient.configuration
    rows = samples.map do |sample|
      conversation = Conversation.find_by!(account_id: account_id, display_id: sample.fetch('conversation_display_id'))
      raise ArgumentError, 'Contact is redacted' if conversation.contact.additional_attributes['umi_profile_redacted']

      as_of = Time.current
      messages = Umi::Funnel::ClassificationContext.public_messages(conversation)
      watermark = messages.incoming.maximum(:id)
      context = Umi::Funnel::ClassificationContext.new(conversation, watermark: watermark, cutoff: messages.maximum(:id),
                                                                     boundary: Umi::Funnel::Configuration.started_at, as_of: as_of).build
      { sample: sample.fetch('sample'), conversation_display_id: conversation.display_id, conversation_id: conversation.id,
        context: context, input_bytes: Umi::Funnel::ClassificationClient.request_bytes(context),
        warning: Umi::Funnel::ClassificationClient.uncertainty(context, config), proposal: nil, failure: nil,
        human_expectations: sample.fetch('corrections', []), historical_original: sample,
        evidence_mapping: 'Historical evidence is retained as original data; ordinal IDs are not mapped to persisted IDs.' }
    end
    { version: Umi::Funnel::ClassificationContext::VERSION, account_id: account_id, exported_at: Time.current.iso8601,
      configuration: config, configuration_digest: Umi::Funnel::ClassificationClient.configuration_digest(config),
      manifest_digest: Digest::SHA256.hexdigest(JSON.generate(manifest)), samples: rows }
  end

  def self.infer(packet) # rubocop:disable Metrics/MethodLength
    unless packet.fetch('configuration') == Umi::Funnel::ClassificationClient.configuration
      raise ArgumentError,
            'Review configuration changed; export a fresh packet'
    end

    result = packet.deep_dup
    result.fetch('samples').each do |sample|
      input = sample.fetch('context').deep_symbolize_keys
      warning = Umi::Funnel::ClassificationClient.uncertainty(input)
      proposal = if warning
                   { 'status' => 'uncertain', 'topics' => [], 'roles' => [], 'reason' => warning.humanize, 'evidence_message_ids' => [] }
                 else
                   Umi::Funnel::ClassificationClient.new.classify(input)
                 end
      sample['proposal'] = Umi::Funnel::ClassificationClient.validate!(proposal, input)
      sample['failure'] = nil
    rescue StandardError => e
      sample['proposal'] = nil
      sample['failure'] = e.class.name
    end
    result['inferred_at'] = Time.current.iso8601
    result
  end

  def self.write_new!(path, packet)
    directory = File.dirname(File.expand_path(path))
    FileUtils.mkdir_p(directory, mode: 0o700)
    raise ArgumentError, 'Review directory must be private' unless File.stat(directory).mode.nobits?(0o077)

    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(packet)) }
  end
end
