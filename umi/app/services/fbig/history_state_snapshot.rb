# frozen_string_literal: true

require 'digest'
require 'pathname'

# A bounded, PII-free view of every database row the history importer owns or
# may link to. The snapshot is captured in one repeatable-read transaction so
# an interrupted host process can later attribute already-committed work.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:disable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
class Umi::Fbig::HistoryStateSnapshot
  Row = Data.define(:values) do
    def entity
      values.fetch(0)
    end

    def platform
      values.fetch(1)
    end

    def key
      [entity, platform, values.fetch(2).to_i]
    end
  end
  Artifact = Data.define(:bytes, :account_id, :inbox_id, :platforms, :captured_at, :rows, :sha256)

  class InvalidSnapshot < StandardError; end

  PLATFORMS = %w[messenger instagram].freeze
  ENTITIES = %w[
    active_storage_attachment active_storage_blob archive attachment contact contact_inbox message
  ].freeze
  PLATFORM_ENTITIES = (ENTITIES - %w[contact contact_inbox]).freeze
  HASH_PATTERN = /\A[0-9a-f]{64}\z/
  MAX_BYTES = 128.megabytes
  MAX_ROWS = 100_000
  MAX_LINE_BYTES = 1_024
  ALLOWED_BASENAMES = %w[
    fbig-history-production-prestate-v1.tsv
    fbig-history-production-poststate-v1.tsv
    fbig-history-backup-messenger-state-v1.tsv
    fbig-history-backup-instagram-state-v1.tsv
  ].freeze

  def self.capture(inbox, platforms:, renewer: nil)
    selected_platforms = normalize_platforms!(platforms)
    captured_at = Time.current.utc
    checkpoint!(renewer)
    raise InvalidSnapshot if preflight_row_count(inbox, selected_platforms) > MAX_ROWS

    rows = ActiveRecord::Base.transaction(isolation: :repeatable_read, requires_new: true) do
      capture_rows(inbox, selected_platforms, renewer)
    end
    checkpoint!(renewer)
    rows = deduplicate_rows(rows)
    raise InvalidSnapshot if rows.size > MAX_ROWS

    ordered_rows = rows.sort_by(&:key)
    raise InvalidSnapshot unless ordered_rows.map(&:key).uniq.size == ordered_rows.size

    lines = [
      "schema_version\t1",
      "account_id\t#{inbox.account_id}",
      "inbox_id\t#{inbox.id}",
      "platforms\t#{selected_platforms.join(',')}",
      "captured_at\t#{captured_at.strftime('%Y-%m-%dT%H:%M:%SZ')}",
      "row_count\t#{ordered_rows.size}",
      *ordered_rows.map { |row| row.values.join("\t") }
    ]
    raise InvalidSnapshot if lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    bytes = "#{lines.join("\n")}\n"
    raise InvalidSnapshot if bytes.bytesize > MAX_BYTES

    Artifact.new(
      bytes: bytes,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      platforms: selected_platforms.freeze,
      captured_at: captured_at,
      rows: ordered_rows.freeze,
      sha256: Digest::SHA256.hexdigest(bytes)
    )
  rescue Umi::Fbig::TypedValueDigest::UnsupportedValue => e
    raise InvalidSnapshot, e.message
  end

  def self.deduplicate_rows(rows)
    rows.group_by(&:key).map do |_key, matches|
      raise InvalidSnapshot unless matches.map(&:values).uniq.one?

      matches.first
    end
  end
  private_class_method :deduplicate_rows

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidSnapshot unless text.valid_encoding? && text.end_with?("\n") && text.bytesize <= MAX_BYTES
    raise InvalidSnapshot if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidSnapshot if lines.size < 6 || lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    headers = lines.first(6).map { |line| line.split("\t", -1) }
    expected_names = %w[schema_version account_id inbox_id platforms captured_at row_count]
    raise InvalidSnapshot unless headers.map(&:first) == expected_names && headers.all? { |parts| parts.size == 2 }
    raise InvalidSnapshot unless headers.dig(0, 1) == '1'
    raise InvalidSnapshot unless headers.values_at(1, 2, 5).all? { |parts| canonical_integer?(parts.last) }

    account_id = Integer(headers.dig(1, 1), 10)
    inbox_id = Integer(headers.dig(2, 1), 10)
    raise InvalidSnapshot unless account_id.positive? && inbox_id.positive?

    platforms = normalize_platforms!(headers.dig(3, 1).split(','))
    captured_at = canonical_time!(headers.dig(4, 1))
    row_count = Integer(headers.dig(5, 1), 10)
    raise InvalidSnapshot if row_count > MAX_ROWS || lines.size != row_count + 6

    rows = lines.drop(6).map { |line| parse_row(line, platforms) }
    raise InvalidSnapshot unless rows.map(&:key) == rows.map(&:key).sort
    raise InvalidSnapshot unless rows.map(&:key).uniq.size == rows.size

    Artifact.new(
      bytes: text,
      account_id: account_id,
      inbox_id: inbox_id,
      platforms: platforms.freeze,
      captured_at: captured_at,
      rows: rows.freeze,
      sha256: Digest::SHA256.hexdigest(text)
    )
  rescue ArgumentError
    raise InvalidSnapshot
  end

  def self.load(path:, checksum_path:, expected_uid: 0)
    basename = Pathname.new(path.to_s).basename.to_s
    raise InvalidSnapshot unless ALLOWED_BASENAMES.include?(basename)

    data_path = canonical_path!(path, basename)
    digest_path = canonical_path!(checksum_path, "#{basename}.sha256")
    raise InvalidSnapshot unless data_path.dirname == digest_path.dirname

    verify_directory!(data_path.dirname, expected_uid)
    bytes = read_artifact!(data_path, expected_uid)
    checksum = read_artifact!(digest_path, expected_uid)
    expected = "#{Digest::SHA256.hexdigest(bytes)}  #{data_path.basename}\n"
    raise InvalidSnapshot unless checksum == expected

    parse(bytes)
  rescue SystemCallError
    raise InvalidSnapshot
  end

  def self.capture_and_seal!(inbox, platforms:, directory:, basename:, expected_uid: 0, renewer: nil)
    raise InvalidSnapshot unless ALLOWED_BASENAMES.include?(basename)

    directory_path = Pathname.new(directory.to_s)
    verify_directory!(directory_path, expected_uid)
    data_path = directory_path.join(basename)
    checksum_path = directory_path.join("#{basename}.sha256")
    if data_path.exist? && checksum_path.exist?
      artifact = load(path: data_path.to_s, checksum_path: checksum_path.to_s, expected_uid: expected_uid)
      validate_scope!(artifact, inbox, platforms)
      return artifact
    end
    raise InvalidSnapshot if checksum_path.exist?

    if data_path.exist?
      artifact = parse(read_artifact!(data_path, expected_uid))
      validate_scope!(artifact, inbox, platforms)
      checkpoint!(renewer)
      publish_file_no_replace!(
        checksum_path,
        "#{artifact.sha256}  #{basename}\n"
      )
      fsync_directory!(directory_path)
      return artifact
    end

    artifact = capture(inbox, platforms: platforms, renewer: renewer)
    checkpoint!(renewer)
    publish_file_no_replace!(data_path, artifact.bytes)
    fsync_directory!(directory_path)
    checkpoint!(renewer)
    publish_file_no_replace!(checksum_path, "#{artifact.sha256}  #{basename}\n")
    fsync_directory!(directory_path)
    artifact
  rescue SystemCallError
    raise InvalidSnapshot
  end

  def self.capture_rows(inbox, platforms, renewer)
    rows = []
    contact_inboxes = inbox.contact_inboxes.order(:id).to_a
    contacts = Contact.where(id: contact_inboxes.map(&:contact_id).uniq).order(:id).index_by(&:id)
    contact_inboxes.each do |contact_inbox|
      checkpoint!(renewer)
      contact = contacts.fetch(contact_inbox.contact_id)
      raise InvalidSnapshot unless contact.account_id == inbox.account_id

      rows << row(
        'contact',
        'shared',
        contact.id,
        contact.account_id,
        0,
        contact.id,
        { 'account_id' => contact.account_id }
      )
      rows << row(
        'contact_inbox',
        'shared',
        contact_inbox.id,
        contact.id,
        inbox.id,
        contact_inbox.source_id.to_s,
        {
          'contact_id' => contact_inbox.contact_id,
          'inbox_id' => contact_inbox.inbox_id
        }
      )
    end

    archives = importer_archives(inbox, platforms)
    contact_inboxes_by_id = contact_inboxes.index_by(&:id)
    archives.each do |archive|
      checkpoint!(renewer)
      marker = validate_archive!(archive, inbox, platforms)
      platform = marker.fetch('platform')
      thread_id = marker.fetch('thread_id')
      rows << row(
        'archive',
        platform,
        archive.id,
        archive.contact_id,
        archive.contact_inbox_id,
        [archive.identifier, thread_id],
        archive_protected_state(archive, marker),
        activity_state: archive_activity_state(archive),
        configuration_state: marker.fetch('configuration'),
        byte_size: archive.messages.count
      )
      contacts.fetch(archive.contact_id)
      contact_inboxes_by_id.fetch(archive.contact_inbox_id)
      capture_messages(rows, archive, platform, thread_id, renewer)
    end
    rows
  end
  private_class_method :capture_rows

  def self.preflight_row_count(inbox, platforms)
    archives = importer_archive_scope(inbox, platforms)
    messages = Message.where(conversation_id: archives.select(:id))
    attachments = Attachment.where(message_id: messages.select(:id))
    storage_attachments = ActiveStorage::Attachment.where(
      record_type: 'Attachment',
      record_id: attachments.select(:id)
    )

    (inbox.contact_inboxes.count * 2) +
      archives.count +
      messages.count +
      attachments.count +
      storage_attachments.count +
      storage_attachments.distinct.count(:blob_id)
  end
  private_class_method :preflight_row_count

  def self.importer_archives(inbox, platforms)
    importer_archive_scope(inbox, platforms).order(:id).to_a
  end
  private_class_method :importer_archives

  def self.importer_archive_scope(inbox, platforms)
    base = Conversation.where(account_id: inbox.account_id, inbox_id: inbox.id)
    prefixes = platforms.map do |platform|
      prefix = ActiveRecord::Base.sanitize_sql_like("umi-fbig-history:#{inbox.id}:#{platform}:")
      "#{prefix}%"
    end
    identifier_clauses = Array.new(prefixes.size, 'identifier LIKE ?')
    base.where(
      "(#{identifier_clauses.join(' OR ')}) OR " \
      "additional_attributes -> 'umi_history_import' ->> 'platform' IN (?)",
      *prefixes,
      platforms
    )
  end
  private_class_method :importer_archive_scope

  def self.validate_archive!(archive, inbox, platforms)
    marker = archive.additional_attributes['umi_history_import']
    valid = marker.is_a?(Hash) &&
            marker.keys.to_set == %w[schema_version platform thread_id configuration].to_set &&
            marker['schema_version'] == 1 &&
            platforms.include?(marker['platform']) &&
            marker['thread_id'].is_a?(String) &&
            marker['thread_id'].present? &&
            marker['configuration'].is_a?(Hash) &&
            archive.identifier == "umi-fbig-history:#{inbox.id}:#{marker['platform']}:#{marker['thread_id']}"
    raise InvalidSnapshot unless valid

    marker
  end
  private_class_method :validate_archive!

  def self.capture_messages(rows, archive, platform, thread_id, renewer)
    archive.messages.order(:id).find_each do |message|
      checkpoint!(renewer)
      marker = message.additional_attributes
      valid = marker['umi_history_import'] == true &&
              marker['umi_history_schema_version'] == 1 &&
              marker['umi_history_platform'] == platform &&
              marker['umi_history_thread_id'] == thread_id
      raise InvalidSnapshot unless valid

      rows << row(
        'message',
        platform,
        message.id,
        archive.id,
        message.message_type,
        message.source_id.to_s,
        message.attributes,
        byte_size: message.attachments.count
      )
      capture_attachments(rows, message, platform, renewer)
    end
  end
  private_class_method :capture_messages

  def self.capture_attachments(rows, message, platform, renewer)
    message.attachments.order(:id).find_each do |attachment|
      checkpoint!(renewer)
      rows << row(
        'attachment',
        platform,
        attachment.id,
        message.id,
        0,
        attachment.id,
        attachment.attributes
      )
      storage_attachments = ActiveStorage::Attachment
                            .where(record_type: 'Attachment', record_id: attachment.id)
                            .order(:id).to_a
      raise InvalidSnapshot if storage_attachments.many?

      storage_attachments.each do |storage_attachment|
        blob = ActiveStorage::Blob.find(storage_attachment.blob_id)
        rows << row(
          'active_storage_attachment',
          platform,
          storage_attachment.id,
          attachment.id,
          blob.id,
          [storage_attachment.record_type, storage_attachment.name],
          storage_attachment.attributes
        )
        rows << row(
          'active_storage_blob',
          platform,
          blob.id,
          0,
          0,
          blob.key,
          blob.attributes,
          byte_size: blob.byte_size
        )
      end
    end
  end
  private_class_method :capture_attachments

  def self.checkpoint!(renewer)
    raise InvalidSnapshot if renewer && !renewer.call
  rescue InvalidSnapshot
    raise
  rescue StandardError
    raise InvalidSnapshot
  end
  private_class_method :checkpoint!

  ARCHIVE_ACTIVITY_FIELDS = %w[agent_last_seen_at created_at last_activity_at updated_at].freeze

  def self.archive_protected_state(archive, marker)
    attributes = archive.attributes.except(*ARCHIVE_ACTIVITY_FIELDS, 'additional_attributes')
    additional_attributes = archive.additional_attributes.deep_dup
    history_marker = additional_attributes.fetch('umi_history_import').deep_dup
    history_marker.delete('configuration')
    additional_attributes['umi_history_import'] = history_marker
    attributes.merge('additional_attributes' => additional_attributes, 'marker_identity' => marker.except('configuration'))
  end
  private_class_method :archive_protected_state

  def self.archive_activity_state(archive)
    archive.attributes.slice(*ARCHIVE_ACTIVITY_FIELDS)
  end
  private_class_method :archive_activity_state

  def self.row(entity, platform, local_id, parent_id, secondary_id, identity, protected_state,
               activity_state: nil, configuration_state: nil, byte_size: 0)
    Row.new(
      values: [
        entity,
        platform,
        local_id.to_s,
        parent_id.to_s,
        secondary_id.to_s,
        Umi::Fbig::TypedValueDigest.hexdigest(identity),
        Umi::Fbig::TypedValueDigest.hexdigest(protected_state),
        optional_digest(activity_state),
        optional_digest(configuration_state),
        byte_size.to_s
      ].freeze
    )
  end
  private_class_method :row

  def self.optional_digest(value)
    value.nil? ? '-' : Umi::Fbig::TypedValueDigest.hexdigest(value)
  end
  private_class_method :optional_digest

  def self.parse_row(line, platforms)
    values = line.split("\t", -1)
    raise InvalidSnapshot unless values.size == 10 && ENTITIES.include?(values[0])

    allowed_platforms = PLATFORM_ENTITIES.include?(values[0]) ? platforms : %w[shared]
    raise InvalidSnapshot unless allowed_platforms.include?(values[1])
    raise InvalidSnapshot unless values.values_at(2, 3, 9).all? { |value| canonical_integer?(value) }
    raise InvalidSnapshot unless values[4].match?(/\A[a-z0-9_]+\z/)
    raise InvalidSnapshot unless values[2].to_i.positive?
    raise InvalidSnapshot unless values.values_at(5, 6).all? { |value| value.match?(HASH_PATTERN) }
    raise InvalidSnapshot unless values.values_at(7, 8).all? { |value| value == '-' || value.match?(HASH_PATTERN) }

    Row.new(values: values.freeze)
  end
  private_class_method :parse_row

  def self.normalize_platforms!(platforms)
    normalized = Array(platforms).map(&:to_s)
    raise InvalidSnapshot if normalized.empty? || normalized.uniq.size != normalized.size
    raise InvalidSnapshot unless (normalized - PLATFORMS).empty?

    PLATFORMS.select { |platform| normalized.include?(platform) }
  end
  private_class_method :normalize_platforms!

  def self.validate_scope!(artifact, inbox, platforms)
    expected_platforms = normalize_platforms!(platforms)
    raise InvalidSnapshot unless artifact.account_id == inbox.account_id &&
                                 artifact.inbox_id == inbox.id &&
                                 artifact.platforms == expected_platforms
  end
  private_class_method :validate_scope!

  def self.canonical_integer?(value)
    value.match?(/\A(?:0|[1-9][0-9]*)\z/)
  end
  private_class_method :canonical_integer?

  def self.canonical_time!(value)
    parsed = Time.iso8601(value)
    raise InvalidSnapshot unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value

    parsed.utc
  rescue ArgumentError
    raise InvalidSnapshot
  end
  private_class_method :canonical_time!

  def self.canonical_path!(value, basename)
    path = Pathname.new(value.to_s)
    raise InvalidSnapshot unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

    path
  end
  private_class_method :canonical_path!

  def self.verify_directory!(path, expected_uid)
    stat = File.lstat(path)
    raise InvalidSnapshot unless stat.directory? &&
                                 !stat.symlink? &&
                                 stat.uid == expected_uid &&
                                 (stat.mode & 0o777) == 0o700
  end
  private_class_method :verify_directory!

  def self.read_artifact!(path, expected_uid)
    bytes = nil
    opened_stat = nil
    File.open(path, 'rb') do |file|
      opened_stat = file.stat
      raise InvalidSnapshot unless opened_stat.file? &&
                                   opened_stat.uid == expected_uid &&
                                   opened_stat.nlink == 1 &&
                                   (opened_stat.mode & 0o777) == 0o400

      bytes = file.read
    end
    stat = File.lstat(path)
    raise InvalidSnapshot if stat.symlink?
    raise InvalidSnapshot unless stat.dev == opened_stat.dev && stat.ino == opened_stat.ino

    bytes
  end
  private_class_method :read_artifact!

  def self.publish_file_no_replace!(path, bytes)
    temporary = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(16)}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
    File.chmod(0o400, temporary)
    File.link(temporary, path)
  ensure
    File.unlink(temporary) if temporary&.exist?
  end
  private_class_method :publish_file_no_replace!

  def self.fsync_directory!(directory)
    File.open(directory, File::RDONLY, &:fsync)
  end
  private_class_method :fsync_directory!
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
