# frozen_string_literal: true

# UMI-owned call record (Twilio voice / WhatsApp), on the existing `calls` table.
# Replaces the premium-gated enterprise Call model; the host :call/:calls associations
# are repointed here in config/initializers/zz_umi_voice.rb.
class Umi::Call < ApplicationRecord
  self.table_name = 'calls'

  STATUSES = %w[ringing in_progress completed no_answer failed missed].freeze
  TERMINAL_STATUSES = %w[completed no_answer failed missed].freeze

  # Chatwoot's native calls API serializes `direction` through this label
  # (stored direction → wire direction). Mirror it so the account `calls`
  # association, which points here, renders through that serializer unchanged.
  DISPLAY_DIRECTION = { 'incoming' => 'inbound', 'outgoing' => 'outbound' }.freeze

  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :contact
  belongs_to :message, optional: true
  belongs_to :accepted_by_agent, class_name: 'User', optional: true

  enum :provider, { twilio: 0, whatsapp: 1 }
  enum :direction, { incoming: 0, outgoing: 1 }

  store_accessor :meta, :conference_sid, :recording_sid, :parent_call_sid, :initiated_at, :ended_at

  validates :provider_call_id, presence: true, uniqueness: { scope: :provider }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # Wire format the MIT frontend reads (helper/voice.js): hyphenated status, raw direction.
  def display_status
    status.to_s.tr('_', '-')
  end

  def direction_label
    DISPLAY_DIRECTION[direction]
  end

  def recording_url
    return unless recording.attached?

    Rails.application.routes.url_helpers.rails_blob_url(recording)
  rescue StandardError
    nil
  end

  def push_event_data
    {
      id: id,
      provider: provider,
      provider_call_id: provider_call_id,
      status: display_status,
      direction: direction,
      duration_seconds: duration_seconds,
      accepted_by_agent_id: accepted_by_agent_id,
      accepted_by_agent_name: accepted_by_agent&.available_name,
      recording_url: recording_url,
      end_reason: end_reason
    }
  end

  has_one_attached :recording
end
