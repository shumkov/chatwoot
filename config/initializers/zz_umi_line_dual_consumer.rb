# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  job = Webhooks::LineEventsJob
  required_keywords = %i[params signature post_body]
  actual_keywords = job.instance_method(:perform).parameters.filter_map { |kind, name| name if kind == :key }

  unless job.private_method_defined?(:valid_event_payload?) && job.private_method_defined?(:valid_post_body?) &&
         required_keywords.all? { |keyword| actual_keywords.include?(keyword) }
    raise 'UMI zz_umi_line_dual_consumer: Webhooks::LineEventsJob contract changed — rebase the patch'
  end

  job.log_arguments = false
  job.prepend(Umi::Line::LineEventsJobForwarding) unless job.ancestors.include?(Umi::Line::LineEventsJobForwarding)

  Rails.logger.info("[umi-line-dual] stage=boot enabled=#{Umi::Line::DualConsumer.enabled?} " \
                    "url_present=#{Umi::Line::DualConsumer.endpoint.present?} " \
                    "target_channel_present=#{Umi::Line::DualConsumer.target_channel_id.present?}")
end
