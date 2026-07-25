# frozen_string_literal: true

require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
class Umi::Fbig::AvatarIntentStore
  Intent = Data.define(:sequence, :blob_key, :contact_inbox_id, :source_id_sha256)
  Entry = Data.define(
    :sequence,
    :blob_key,
    :contact_inbox_id,
    :source_id_sha256,
    :outcome,
    :blob_id,
    :attachment_id,
    :object_sha256
  )
  ReconcileResult = Data.define(:statuses, :entries)

  class InvalidStore < StandardError; end
  class LeaseLost < StandardError; end

  MAX_INTENTS = 1_000_000
  INTENT_PATTERN = /\Aintent-(0|[1-9][0-9]*)\.tsv\z/
  TEMP_PATTERN = /\A\.intent-(0|[1-9][0-9]*)\.tsv\.[0-9a-f]{32}\.tmp\z/
  BLOB_KEY_PATTERN = /\A[0-9a-f]{48}\z/
  HASH_PATTERN = /\A[0-9a-f]{64}\z/

  def initialize(directory:, expected_uid: 0)
    @directory = Pathname.new(directory.to_s)
    @expected_uid = expected_uid
    validate_directory!
  end

  def create!(source_id:, contact_inbox_id:)
    cleanup_temporary_files!
    paths = validated_intent_paths
    sequence = paths.empty? ? 1 : sequence_from_path(paths.last) + 1
    raise InvalidStore unless sequence.between?(1, MAX_INTENTS)

    intent = Intent.new(
      sequence: sequence,
      blob_key: collision_free_blob_key!,
      contact_inbox_id: Integer(contact_inbox_id),
      source_id_sha256: Umi::Fbig::TypedValueDigest.hexdigest(source_id.to_s)
    )
    validate_intent!(intent)
    seal_intent!(intent)
    intent
  rescue SystemCallError, ArgumentError
    raise InvalidStore
  end

  def reconcile!(renewer: nil)
    cleanup_temporary_files!
    entries = validated_intent_paths.map do |path|
      checkpoint!(renewer)
      reconcile_intent!(read_intent!(path))
    end
    statuses = {
      attached: entries.count { |entry| entry.outcome == 'attached' },
      absent: entries.count { |entry| entry.outcome == 'absent' }
    }
    ReconcileResult.new(statuses: statuses, entries: entries.freeze)
  end

  private

  def validate_directory!
    raise InvalidStore unless @directory.absolute? && @directory.cleanpath == @directory

    stat = File.lstat(@directory)
    raise InvalidStore unless stat.directory? &&
                              !stat.symlink? &&
                              stat.uid == @expected_uid &&
                              (stat.mode & 0o777) == 0o700
  rescue SystemCallError
    raise InvalidStore
  end

  def cleanup_temporary_files!
    children = Dir.children(@directory)
    invalid = children.reject { |name| name.match?(INTENT_PATTERN) || name.match?(TEMP_PATTERN) }
    raise InvalidStore if invalid.any?

    children.grep(TEMP_PATTERN).each do |name|
      path = @directory.join(name)
      stat = File.lstat(path)
      raise InvalidStore unless stat.file? &&
                                !stat.symlink? &&
                                stat.uid == @expected_uid &&
                                stat.nlink == 1

      File.unlink(path)
    end
    fsync_directory!
  rescue SystemCallError
    raise InvalidStore
  end

  def validated_intent_paths
    paths = Dir.children(@directory).filter_map do |name|
      @directory.join(name) if name.match?(INTENT_PATTERN)
    end
    paths.sort_by! { |path| sequence_from_path(path) }
    sequences = paths.map { |path| sequence_from_path(path) }
    expected = sequences.empty? ? [] : (1..sequences.last).to_a
    raise InvalidStore unless sequences == expected && sequences.size <= MAX_INTENTS

    paths
  end

  def sequence_from_path(path)
    Integer(path.basename.to_s.match(INTENT_PATTERN)[1], 10)
  rescue NoMethodError, ArgumentError
    raise InvalidStore
  end

  def collision_free_blob_key!
    100.times do
      key = SecureRandom.hex(24)
      next if ActiveStorage::Blob.exists?(key: key)
      next if ActiveStorage::Blob.service.exist?(key)

      return key
    end
    raise InvalidStore
  end

  def seal_intent!(intent)
    final_path = @directory.join("intent-#{intent.sequence}.tsv")
    raise InvalidStore if final_path.exist?

    temporary_path = @directory.join(".intent-#{intent.sequence}.tsv.#{SecureRandom.hex(16)}.tmp")
    File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(serialize(intent))
      file.flush
      file.fsync
    end
    File.chmod(0o400, temporary_path)
    File.rename(temporary_path, final_path)
    fsync_directory!
  rescue StandardError
    File.unlink(temporary_path) if temporary_path&.exist?
    raise
  end

  def serialize(intent)
    [
      "schema_version\t1",
      "sequence\t#{intent.sequence}",
      "blob_key\t#{intent.blob_key}",
      "contact_inbox_id\t#{intent.contact_inbox_id}",
      "source_id_sha256\t#{intent.source_id_sha256}"
    ].join("\n") << "\n"
  end

  def read_intent!(path)
    bytes = read_locked_file!(path)
    text = bytes.force_encoding(Encoding::UTF_8)
    raise InvalidStore unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidStore if text.include?("\r") || text.include?("\0")

    fields = text.lines(chomp: true).map { |line| line.split("\t", -1) }
    names = %w[schema_version sequence blob_key contact_inbox_id source_id_sha256]
    raise InvalidStore unless fields.size == names.size &&
                              fields.all? { |parts| parts.size == 2 } &&
                              fields.map(&:first) == names

    values = fields.to_h
    raise InvalidStore unless values.fetch('schema_version') == '1'

    intent = Intent.new(
      sequence: Integer(values.fetch('sequence'), 10),
      blob_key: values.fetch('blob_key'),
      contact_inbox_id: Integer(values.fetch('contact_inbox_id'), 10),
      source_id_sha256: values.fetch('source_id_sha256')
    )
    validate_intent!(intent)
    raise InvalidStore unless path.basename.to_s == "intent-#{intent.sequence}.tsv"

    intent
  rescue ArgumentError, KeyError
    raise InvalidStore
  end

  def validate_intent!(intent)
    raise InvalidStore unless intent.sequence.between?(1, MAX_INTENTS) &&
                              intent.blob_key.match?(BLOB_KEY_PATTERN) &&
                              intent.contact_inbox_id.positive? &&
                              intent.source_id_sha256.match?(HASH_PATTERN)
  end

  def reconcile_intent!(intent)
    contact_inbox = ContactInbox.find_by(id: intent.contact_inbox_id)
    valid_identity = contact_inbox &&
                     Umi::Fbig::TypedValueDigest.hexdigest(contact_inbox.source_id.to_s) == intent.source_id_sha256
    raise InvalidStore unless valid_identity

    contact = Contact.find_by(id: contact_inbox.contact_id)
    raise InvalidStore unless contact && contact.account_id == contact_inbox.inbox.account_id

    blob = ActiveStorage::Blob.find_by(key: intent.blob_key)
    return purge_unindexed_object!(intent) unless blob

    attachments = ActiveStorage::Attachment.where(blob_id: blob.id).to_a
    return purge_missing_object_blob!(intent, blob) if attachments.empty? && !blob.service.exist?(blob.key)
    raise InvalidStore unless blob.service.exist?(blob.key)
    return purge_unattached_blob!(intent, blob) if attachments.empty?

    valid_attachment = attachments.one? &&
                       attachments.first.name == 'avatar' &&
                       attachments.first.record_type == 'Contact' &&
                       attachments.first.record_id == contact.id &&
                       ActiveStorage::Attachment.where(
                         name: 'avatar',
                         record_type: 'Contact',
                         record_id: contact.id
                       ).where.not(id: attachments.first.id).none?
    raise InvalidStore unless valid_attachment

    entry_for_attached(intent, blob, attachments.first)
  end

  def purge_unindexed_object!(intent)
    service = ActiveStorage::Blob.service
    service.delete(intent.blob_key) if service.exist?(intent.blob_key)
    raise InvalidStore if service.exist?(intent.blob_key)

    entry_for_absent(intent)
  end

  def purge_unattached_blob!(intent, blob)
    blob.purge
    raise InvalidStore if ActiveStorage::Blob.exists?(id: blob.id) || blob.service.exist?(intent.blob_key)

    entry_for_absent(intent)
  end

  def purge_missing_object_blob!(intent, blob)
    blob.destroy!
    raise InvalidStore if ActiveStorage::Blob.exists?(id: blob.id) || blob.service.exist?(intent.blob_key)

    entry_for_absent(intent)
  end

  def entry_for_attached(intent, blob, attachment)
    digest = Digest::SHA256.new
    blob.service.download(blob.key) { |chunk| digest << chunk }
    Entry.new(
      sequence: intent.sequence,
      blob_key: intent.blob_key,
      contact_inbox_id: intent.contact_inbox_id,
      source_id_sha256: intent.source_id_sha256,
      outcome: 'attached',
      blob_id: blob.id,
      attachment_id: attachment.id,
      object_sha256: digest.hexdigest
    )
  rescue ActiveStorage::FileNotFoundError
    raise InvalidStore
  end

  def entry_for_absent(intent)
    Entry.new(
      sequence: intent.sequence,
      blob_key: intent.blob_key,
      contact_inbox_id: intent.contact_inbox_id,
      source_id_sha256: intent.source_id_sha256,
      outcome: 'absent',
      blob_id: 0,
      attachment_id: 0,
      object_sha256: '-'
    )
  end

  def read_locked_file!(path)
    bytes = nil
    opened_stat = nil
    File.open(path, 'rb') do |file|
      opened_stat = file.stat
      raise InvalidStore unless opened_stat.file? &&
                                opened_stat.uid == @expected_uid &&
                                opened_stat.nlink == 1 &&
                                (opened_stat.mode & 0o777) == 0o400

      bytes = file.read
    end
    stat = File.lstat(path)
    raise InvalidStore if stat.symlink?
    raise InvalidStore unless stat.dev == opened_stat.dev && stat.ino == opened_stat.ino

    bytes
  rescue SystemCallError
    raise InvalidStore
  end

  def fsync_directory!
    File.open(@directory, File::RDONLY, &:fsync)
  end

  def checkpoint!(renewer)
    raise LeaseLost if renewer && !renewer.call
  rescue LeaseLost
    raise
  rescue StandardError
    raise LeaseLost
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity
