# frozen_string_literal: true

# Compares two history snapshots using immutable importer markers for platform
# attribution. Normal summaries must conserve their write counters exactly;
# an interrupted run can omit a summary and still retain an auditable live
# delta for its host-side finalizer.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
class Umi::Fbig::HistoryStateComparator
  Result = Data.define(
    :per_platform,
    :protected_changes,
    :deleted_rows,
    :unattributed_changes,
    :counter_mismatches,
    :zero_write_observed
  ) do
    def success?
      protected_changes.zero? &&
        deleted_rows.zero? &&
        unattributed_changes.zero? &&
        counter_mismatches.empty?
    end
  end

  COUNT_KEYS = %i[
    contacts_created contacts_reused contact_inboxes_created contact_inboxes_reused
    archives_created archive_activity_changed archive_configuration_changed
    messages_created incoming_created outgoing_created attachments_created
    active_storage_attachments_created active_storage_blobs_created contact_activity_changed
    contact_profile_changed
  ].freeze
  SUMMARY_COUNTERS = {
    imported_contacts: :contacts_created,
    imported_archives: :archives_created,
    imported_incoming: :incoming_created,
    imported_outgoing: :outgoing_created,
    imported_messages: :messages_created,
    imported_attachments: :attachments_created,
    marker_normalizations: :archive_configuration_changed
  }.freeze
  SUMMARY_FIELDS = (SUMMARY_COUNTERS.keys + %i[history_evidence_changes_applied]).freeze

  def self.compare(before:, after:, summary_stats: nil, require_zero_writes: false)
    validate_scope!(before, after)
    new(before, after, summary_stats, require_zero_writes).compare
  end

  def self.parse_summary(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless
      text.valid_encoding? && text.end_with?("\n") && text.lines.size == 1
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot if text.include?("\r") || text.include?("\0")

    tokens = text.chomp.split
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless tokens.shift == '[UMI-FBIG]'

    values = {}
    tokens.each do |token|
      key, value = token.split('=', 2)
      valid = key&.match?(/\A[a-z0-9_]+\z/) && value&.match?(/\A[a-zA-Z0-9_,.:-]+\z/)
      raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless valid && values.exclude?(key)

      values[key] = value
    end
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless values.fetch('stage', nil) == 'history_import_summary'

    SUMMARY_FIELDS.index_with do |key|
      value = values.fetch(key.to_s)
      raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless value.match?(/\A(?:0|[1-9][0-9]*)\z/)

      Integer(value, 10)
    end
  rescue KeyError
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot
  end

  def initialize(before, after, summary_stats, require_zero_writes)
    @before = before
    @after = after
    @before_rows = before.rows.index_by(&:key)
    @after_rows = after.rows.index_by(&:key)
    @summary_stats = summary_stats&.to_h&.transform_keys(&:to_sym)
    @require_zero_writes = require_zero_writes
    @per_platform = before.platforms.index_with { COUNT_KEYS.index_with(0) }
    @protected_changes = 0
    @deleted_rows = 0
    @unattributed_changes = 0
  end

  def compare
    archives_before = rows_for(@before, 'archive').index_by(&:key)
    archives_after = rows_for(@after, 'archive').index_by(&:key)
    relevant_contacts = (archives_before.values + archives_after.values).to_set { |row| row.values.fetch(3).to_i }
    relevant_contact_inboxes = (archives_before.values + archives_after.values).to_set { |row| row.values.fetch(4).to_i }

    count_deleted_rows(relevant_contacts, relevant_contact_inboxes)
    count_added_platform_rows
    count_new_archive_relationships(archives_before, archives_after)
    count_changed_rows(relevant_contacts, relevant_contact_inboxes)
    validate_archive_activity_attribution

    mismatches = counter_mismatches
    zero_write_observed = observed_write_count.zero? &&
                          @protected_changes.zero? &&
                          @deleted_rows.zero? &&
                          @unattributed_changes.zero?
    mismatches << 'zero_write_required' if @require_zero_writes && !zero_write_observed

    Result.new(
      per_platform: @per_platform.transform_values(&:freeze).freeze,
      protected_changes: @protected_changes,
      deleted_rows: @deleted_rows,
      unattributed_changes: @unattributed_changes,
      counter_mismatches: mismatches.sort.freeze,
      zero_write_observed: zero_write_observed
    )
  end

  private

  def count_deleted_rows(relevant_contacts, relevant_contact_inboxes)
    (@before_rows.keys - @after_rows.keys).each do |key|
      row = @before_rows.fetch(key)
      next if row.entity == 'contact' && relevant_contacts.exclude?(row.values.fetch(2).to_i)
      next if row.entity == 'contact_inbox' && relevant_contact_inboxes.exclude?(row.values.fetch(2).to_i)

      @deleted_rows += 1
    end
  end

  def count_added_platform_rows
    (@after_rows.keys - @before_rows.keys).each do |key|
      row = @after_rows.fetch(key)
      next if row.platform == 'shared'

      counts = @per_platform.fetch(row.platform)
      case row.entity
      when 'archive'
        counts[:archives_created] += 1
      when 'message'
        counts[:messages_created] += 1
        direction = row.values.fetch(4)
        if direction == 'incoming'
          counts[:incoming_created] += 1
        elsif direction == 'outgoing'
          counts[:outgoing_created] += 1
        else
          @unattributed_changes += 1
        end
      when 'attachment'
        counts[:attachments_created] += 1
      when 'active_storage_attachment'
        counts[:active_storage_attachments_created] += 1
      when 'active_storage_blob'
        counts[:active_storage_blobs_created] += 1
      else
        @unattributed_changes += 1
      end
    end
  end

  def count_new_archive_relationships(archives_before, archives_after)
    new_archives = archives_after.values_at(*(archives_after.keys - archives_before.keys)).compact
    count_relationship(new_archives, entity: 'contact', id_index: 3, created_key: :contacts_created,
                                     reused_key: :contacts_reused)
    count_relationship(
      new_archives,
      entity: 'contact_inbox',
      id_index: 4,
      created_key: :contact_inboxes_created,
      reused_key: :contact_inboxes_reused
    )
  end

  def count_relationship(archives, entity:, id_index:, created_key:, reused_key:)
    archives.group_by { |archive| archive.values.fetch(id_index).to_i }.each do |id, matches|
      platforms = matches.map(&:platform).uniq
      if platforms.one?
        key = [entity, 'shared', id]
        destination = @before_rows.key?(key) ? reused_key : created_key
        @per_platform.fetch(platforms.first)[destination] += 1
      else
        @unattributed_changes += 1
      end
    end
  end

  def count_changed_rows(relevant_contacts, relevant_contact_inboxes)
    (@before_rows.keys & @after_rows.keys).each do |key|
      before_row = @before_rows.fetch(key)
      after_row = @after_rows.fetch(key)
      next if before_row.values == after_row.values
      next if before_row.entity == 'contact' && relevant_contacts.exclude?(before_row.values.fetch(2).to_i)
      next if before_row.entity == 'contact_inbox' &&
              relevant_contact_inboxes.exclude?(before_row.values.fetch(2).to_i)

      if protected_tuple(before_row) != protected_tuple(after_row)
        @protected_changes += 1
        next
      end
      count_allowed_mutable_change(before_row, after_row)
    end
  end

  def protected_tuple(row)
    row.values.first(7)
  end

  def count_allowed_mutable_change(before_row, after_row)
    case before_row.entity
    when 'archive'
      counts = @per_platform.fetch(before_row.platform)
      counts[:archive_activity_changed] += 1 if before_row.values.fetch(7) != after_row.values.fetch(7)
      counts[:archive_configuration_changed] += 1 if before_row.values.fetch(8) != after_row.values.fetch(8)
    else
      @unattributed_changes += 1
    end
  end

  def validate_archive_activity_attribution
    new_messages = (@after_rows.keys - @before_rows.keys).filter_map do |key|
      row = @after_rows.fetch(key)
      row if row.entity == 'message'
    end
    new_message_archives = new_messages.to_set { |row| row.values.fetch(3).to_i }

    rows_for(@before, 'archive').each do |archive|
      after_row = @after_rows[archive.key]
      next unless after_row
      next if archive.values.fetch(7) == after_row.values.fetch(7)
      next if new_message_archives.include?(archive.values.fetch(2).to_i)

      @unattributed_changes += 1
    end
  end

  def counter_mismatches
    return [] unless @summary_stats

    totals = COUNT_KEYS.index_with { |key| @per_platform.values.sum { |counts| counts.fetch(key) } }
    SUMMARY_COUNTERS.filter_map do |summary_key, observed_key|
      summary_key.to_s unless Integer(@summary_stats.fetch(summary_key, 0).to_s, 10) == totals.fetch(observed_key)
    rescue ArgumentError, TypeError
      summary_key.to_s
    end
  end

  def observed_write_count
    write_keys = %i[
      contacts_created contact_inboxes_created archives_created archive_activity_changed
      archive_configuration_changed messages_created attachments_created
      active_storage_attachments_created active_storage_blobs_created contact_activity_changed
      contact_profile_changed
    ]
    @per_platform.values.sum { |counts| write_keys.sum { |key| counts.fetch(key) } }
  end

  def rows_for(artifact, entity)
    artifact.rows.select { |row| row.entity == entity }
  end

  def self.validate_scope!(before, after)
    valid = before.account_id == after.account_id &&
            before.inbox_id == after.inbox_id &&
            before.platforms == after.platforms
    raise Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot unless valid
  end
  private_class_method :validate_scope!
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity
