# frozen_string_literal: true

module Umi::Line::LineEventsJobForwarding
  def perform(params: {}, signature: '', post_body: '')
    enqueue_lumo_forward(params, signature, post_body)
  rescue StandardError => e
    log_enqueue_failure(params, e)
  ensure
    super
  end

  private

  def enqueue_lumo_forward(params, signature, post_body)
    return unless Umi::Line::DualConsumer.target_channel?(params[:line_channel_id])

    @params = params
    return unless valid_event_payload?
    return unless valid_post_body?(post_body, signature)

    enqueued = Umi::Line::ForwardEventsJob.perform_later(
      post_body: post_body,
      signature: signature,
      line_channel_id: params[:line_channel_id]
    )

    unless enqueued
      log_enqueue_failure(params, ActiveJob::EnqueueError.new('forward job was not enqueued'))
      return
    end

    Rails.logger.info("[umi-line-dual] stage=forward_enqueued channel_id=#{params[:line_channel_id]}")
  end

  def log_enqueue_failure(params, error)
    channel_id = params[:line_channel_id].to_s
    Rails.logger.error("[umi-line-dual] stage=enqueue_failed channel_id=#{channel_id} error=#{error.class.name}")
  end
end
