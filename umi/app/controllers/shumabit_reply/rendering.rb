# frozen_string_literal: true

# Shared by the Suggest reply tap and its completion: checks the caller, runs the loader and renders its answer with
# one metadata-only log line.
#
# The caller must come from an interactive sign-in session (the same proof the first-responder claim uses: not an
# access token, and a devise client that belongs to one of the user's session rows) and must be allowed to open the
# conversation natively. A refusal is a 403, never a Pundit error, so the mobile app is not logged out.
module Umi::ShumabitReply::Rendering
  include Umi::Conversations::SignedInSession

  LOG_TAG = '[umi-shumabit-reply]'

  private

  def render_shumabit_reply(conversation, config, mode)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    answer = if shumabit_reply_caller?(conversation)
               Umi::ShumabitReply::Loader.new(conversation: conversation, config: config, mode: mode).call
             else
               Umi::ShumabitReply::Loader.fixed(:forbidden)
             end
    finish_shumabit_reply(answer, conversation, mode, started)
  end

  # The only operator signal for a broken configuration, since every Suggest reply then answers `unavailable`.
  def log_invalid_shumabit_config
    Rails.logger.error("#{LOG_TAG} invalid #{Umi::ShumabitReply::Configuration::NAME} configuration")
  end

  def render_shumabit_unavailable(conversation, mode)
    finish_shumabit_reply(Umi::ShumabitReply::Loader.fixed(:unavailable), conversation, mode,
                          Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  def finish_shumabit_reply(answer, conversation, mode, started)
    answer.headers.each { |name, value| response.set_header(name, value) }
    render json: answer.body, status: answer.http
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("#{LOG_TAG} account=#{Current.account.id} conversation=#{conversation&.display_id || 'none'} " \
                      "mode=#{mode} answer=#{answer.code} http=#{answer.http} ms=#{elapsed}")
  end

  def shumabit_reply_caller?(conversation)
    user, client = signed_in_session_candidate
    user.present? && signed_in_session?(user, client) && policy(conversation).show?
  end
end
