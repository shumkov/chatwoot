# frozen_string_literal: true

# Decides what the native Suggest reply button returns in a configured inbox. It only reads: the current contact, the
# conversation's messages and the bridge's metadata-only status. Customer text comes solely from the reply field of a
# trusted Shumabit note made with knowledge of exactly the current eligible input, and only after the contact is read
# again. Nothing here admits, generates or retries anything.
#
# A tap that finds the bridge still working answers `pending` with two wait headers; a proxy may hold it and then
# re-run this loader in completion mode on current state. Completion never offers another wait.
class Umi::ShumabitReply::Loader
  Answer = Struct.new(:code, :http, :body, :headers)

  STATUS_LIMIT = 50
  # A message younger than this may still be on its way to the bridge.
  YOUNG_SECONDS = 10
  # The lower of the web and mobile composer limits, for the channels the bridge drafts for.
  CHANNEL_LIMITS = { 'Channel::FacebookPage' => 1000, 'Channel::Whatsapp' => 4096, 'Channel::Email' => 25_000,
                     'Channel::WebWidget' => 10_000, 'Channel::Line' => 10_000 }.freeze
  TEXTS = {
    forbidden: 'Shumabit suggestions need a signed-in staff session with access to this conversation.',
    contact_unavailable: 'Shumabit suggestions are not available for this conversation.',
    unavailable: 'Shumabit is unavailable right now; read the latest Shumabit note or tap again later.',
    none: 'The latest message is already a sent reply; there is nothing to suggest.',
    before_activation: 'Shumabit drafts start with messages after its activation.',
    deleted: 'A message this draft answers was deleted; read the thread.',
    too_long: 'The Shumabit draft is longer than this channel allows; open the private note.',
    invalid: 'The Shumabit draft cannot be loaded; open the private note.',
    nothing_new: 'Shumabit found nothing new to answer; read the latest Shumabit note.',
    needs_staff: 'Shumabit needs staff for this; read the latest Shumabit note.',
    draft_invalid: "Shumabit's draft failed validation; read the latest Shumabit note.",
    not_completed: 'Shumabit could not complete this draft; write the reply or ask @shumabit.',
    public_reply_sent: 'A public reply was sent meanwhile; read the thread.',
    resolved: 'The conversation was resolved; Shumabit made no draft.',
    not_received_newer: 'A newer message did not reach Shumabit; write the reply or ask @shumabit.',
    member_deleted: 'A message was deleted meanwhile; write the reply or ask @shumabit.',
    ambiguous: 'Shumabit could not confirm an earlier note, so it is holding this conversation; check the thread and ' \
               'write the reply if none is there.',
    not_received: 'A newer customer message did not reach Shumabit; write the reply or ask @shumabit.',
    no_result: 'There is no current Shumabit draft here; read the latest Shumabit note or write the reply.',
    changed: 'The conversation changed since the last Shumabit note; read the thread.',
    pending: 'Shumabit is still working on this; tap again in a moment.',
    not_finished: 'Shumabit has not finished; check the thread or tap again later.'
  }.freeze
  OUTCOME_CODES = { 'no_reply' => :nothing_new, 'non_actionable' => :nothing_new, 'needs_staff' => :needs_staff,
                    'unsupported' => :needs_staff, 'invalid' => :draft_invalid, 'failed' => :not_completed,
                    'interrupted' => :not_completed, 'public_reply_sent' => :public_reply_sent, 'resolved' => :resolved,
                    'not_received_newer' => :not_received_newer, 'member_deleted' => :member_deleted }.freeze

  def self.fixed(code)
    Answer.new(code, code == :forbidden ? 403 : 422, { error: TEXTS.fetch(code) }, {})
  end

  def initialize(conversation:, config:, mode:)
    @conversation = conversation
    @config = config
    @mode = mode
  end

  def call
    return fixed(:contact_unavailable) if contact_redacted?
    return fixed(:unavailable) unless @config.ready?

    evidence = read
    settled(evidence) || ask_bridge(evidence)
  end

  private

  def fixed(code)
    self.class.fixed(code)
  end

  def read
    Umi::ShumabitReply::Evidence.read(@conversation, bridge_user_id: @config.bridge_user_id)
  end

  # The contact is read fresh every time, so a redaction committed at any earlier point denies.
  def contact_redacted?
    Umi::ShumabitReply::Evidence.redacted?(Contact.find_by(id: @conversation.contact_id))
  end

  # An answer that needs no bridge status, or nil.
  def settled(evidence)
    tail = evidence.tail
    return fixed(:none) if tail.nil? || tail.outgoing?
    return fixed(:before_activation) if tail.created_at.to_i <= @config.eligible_after

    note = evidence.current_note
    outcome_answer(note, evidence) if note
  end

  def ask_bridge(evidence)
    asked = evidence.uncovered_ids(@config.eligible_after)
    return fixed(:unavailable) if asked.size > STATUS_LIMIT

    status = Umi::ShumabitReply::StatusClient.new(@config.bridge_url)
                                             .call(account_id: @conversation.account_id, display_id: @conversation.display_id,
                                                   tail_id: evidence.tail.id, message_ids: asked)
    return fixed(:unavailable) unless status

    # The deciding read comes after the status, so a note that landed meanwhile is served.
    evidence = read
    settled(evidence) || classified(evidence, asked, status)
  end

  def classified(evidence, asked, status) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return fixed(:ambiguous) if status.ambiguous || status.classes.value?('reserved')
    return pending(asked, wait: false) unless evidence.uncovered_ids(@config.eligible_after) == asked
    return pending(asked, wait: true) if status.classes.value?('active')

    unknown = asked.select { |id| status.classes[id] == 'unknown' }
    return pending(asked, wait: false) if young?(evidence.tail) || unknown.any? { |id| young?(evidence.message(id)) }
    return fixed(:not_received) if unknown.any?
    return fixed(:no_result) if asked.any?

    note = evidence.newest_note_naming(evidence.tail.id)
    note && evidence.deleted_member?(note) ? fixed(:deleted) : fixed(:changed)
  end

  def outcome_answer(note, evidence) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    marker = note.marker
    return fixed(OUTCOME_CODES.fetch(marker['outcome'])) unless %w[reply still_applies].include?(marker['outcome'])
    return fixed(:deleted) if evidence.deleted_member?(note)
    return fixed(:deleted) if marker['outcome'] == 'still_applies' && !evidence.live_note?(marker['origin_note_id'])

    limit = CHANNEL_LIMITS[@conversation.inbox.channel_type]
    rule = limit && Umi::ShumabitReply::Evidence.text_check(marker['reply'], limit)
    return fixed(:invalid) unless limit
    return fixed(rule == 'too_long' ? :too_long : :invalid) if rule
    return fixed(:contact_unavailable) if contact_redacted?

    Answer.new(:loaded, 200, { message: marker['reply'] }, {})
  end

  def pending(asked, wait:)
    return fixed(:not_finished) if @mode == :completion

    answer = fixed(:pending)
    answer.headers = wait_headers(asked) if wait
    answer
  end

  # Both values are built from integers only, never from request parameters.
  def wait_headers(asked)
    account_id = @conversation.account_id
    display_id = @conversation.display_id
    { 'X-Umi-Shumabit-Wait' => "a=#{account_id};c=#{display_id};m=#{asked.join(',')};d=#{Time.current.to_i + @config.wait_seconds}",
      'X-Umi-Shumabit-Recheck' => "/api/v1/accounts/#{account_id}/umi/shumabit_reply/#{display_id}/completion" }
  end

  def young?(message)
    message.present? && message.created_at > YOUNG_SECONDS.seconds.ago
  end
end
