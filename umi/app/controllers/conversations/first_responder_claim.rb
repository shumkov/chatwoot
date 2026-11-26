# frozen_string_literal: true

# UMI patch: while the team shares one unassigned queue, the first person who
# answers a conversation becomes its owner, and later replies leave that owner.
#
# A reply claims only when it comes from an interactive sign-in session. An
# agent account can also own the automation's access tokens, so the sender alone
# does not prove a person answered. The request must not be token-authenticated, and
# the client devise validated for it must belong to a session row, which only an
# interactive password, SSO or MFA sign-in creates (impersonation does not).
# This proves an authenticated session of that user, not who is at the keyboard.
#
# The claim runs after the reply is created and committed, in its own row-locked
# transaction, so it can neither roll back the reply nor deadlock with it. It is
# creation-time ownership: a later failed delivery keeps the owner. Design:
# docs/UMI-FIRST-RESPONDER-CLAIM-SPEC.md.
module Umi::Conversations::FirstResponderClaim
  extend ActiveSupport::Concern

  CONFIG_NAME = 'UMI_FIRST_RESPONDER_CLAIM'
  LOG_TAG = '[umi-first-responder-claim]'

  included do
    before_action :capture_first_responder_session, only: :create # rubocop:disable Rails/LexicallyScopedActionFilter
    after_action :claim_for_first_responder, only: :create # rubocop:disable Rails/LexicallyScopedActionFilter
  end

  private

  # Recorded before the action, after authentication and authorisation, so code
  # inside the action that swaps Current.user cannot change who is answering.
  def capture_first_responder_session
    return if authenticate_by_access_token? || !Current.user.is_a?(User)

    @first_responder = Current.user
    @first_responder_client = @token&.client
  end

  def claim_for_first_responder
    return unless first_responder_reply?

    claim_conversation
  rescue StandardError => e
    # The reply is already created and rendered: never turn it into an error.
    Rails.logger.error("#{LOG_TAG} claim failed conversation=#{@conversation&.id} message=#{@message&.id}: #{e.class}")
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
  end

  # The native activity reads Current.user to record a self-assignment.
  def claim_conversation
    previous_user = Current.user
    Current.user = @first_responder
    conversation = Conversation.find(@conversation.id)
    conversation.with_lock('FOR NO KEY UPDATE') do
      next unless conversation.open? && conversation.assignee_id.nil? && conversation.assignee_agent_bot_id.nil?

      conversation.update!(assignee: @first_responder)
    end
  ensure
    Current.user = previous_user
  end

  # Cheap checks first; the configuration and the session row are read last.
  def first_responder_reply? # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return false unless @first_responder && @first_responder_client.present? && response.status < 400
    return false unless @message.outgoing? && !@message.private?
    return false unless @message.sender == @first_responder && @message.send(:human_response?)
    return false unless Array(InstallationConfig.find_by(name: CONFIG_NAME)&.value&.fetch('inbox_ids', nil)).include?(@conversation.inbox_id)
    return false unless @conversation.inbox.inbox_members.exists?(user_id: @first_responder.id)

    @first_responder.user_sessions.exists?(client_id: @first_responder_client)
  end
end
