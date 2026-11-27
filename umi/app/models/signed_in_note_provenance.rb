# frozen_string_literal: true

# UMI patch: a private note records, in content_attributes['umi_signed_in_sender_id'], that its sender wrote it from an
# interactive sign-in session. Shumabit follows only such notes as staff direction. The automation shares a staff
# member's account and writes with that account's access token, so the sender alone proves nothing.
#
# Only a messages request that passed the signed-in session check sets the value, through signed_in_sender. Every other
# create drops any value a client, job or service supplied, and an update may remove the value but never add or change
# it. Writes that skip callbacks (update_column, insert_all) are not guarded. The value proves a signed-in session of
# that user, not who is at the keyboard.
module Umi::SignedInNoteProvenance
  extend ActiveSupport::Concern

  KEY = 'umi_signed_in_sender_id'
  STATE = :umi_signed_in_note_sender_id

  # Marks private outgoing notes sent by this user while the block runs, on this thread only.
  def self.signed_in_sender(user_id)
    previous = ActiveSupport::IsolatedExecutionState[STATE]
    ActiveSupport::IsolatedExecutionState[STATE] = user_id
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[STATE] = previous
  end

  included do
    before_create :record_signed_in_note_provenance
    before_update :keep_signed_in_note_provenance
  end

  private

  def record_signed_in_note_provenance
    signed_in_id = ActiveSupport::IsolatedExecutionState[STATE]
    signed_in = signed_in_note?(signed_in_id)
    return if !signed_in && content_attributes.blank?

    attributes = content_attributes.to_h.with_indifferent_access
    return unless signed_in || attributes.key?(KEY)

    self.content_attributes = signed_in ? attributes.merge(KEY => signed_in_id) : attributes.except(KEY)
  end

  def signed_in_note?(signed_in_id)
    signed_in_id.present? && private? && outgoing? && sender_type == 'User' && sender_id == signed_in_id
  end

  def keep_signed_in_note_provenance
    return unless content_attributes_changed?

    previous = (content_attributes_was || {}).with_indifferent_access[KEY]
    attributes = (content_attributes || {}).with_indifferent_access
    return if attributes[KEY].nil? || attributes[KEY] == previous

    self.content_attributes = previous.nil? ? attributes.except(KEY) : attributes.merge(KEY => previous)
  end
end
