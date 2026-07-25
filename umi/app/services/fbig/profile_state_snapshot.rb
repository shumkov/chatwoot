# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
class Umi::Fbig::ProfileStateSnapshot
  Row = Data.define(:values) do
    def key
      [values.fetch(1).to_i, values.fetch(2)]
    end

    def name_state
      values.fetch(6)
    end

    def username_state
      values.fetch(8)
    end

    def avatar_state
      values.fetch(21)
    end
  end
  Artifact = Data.define(:bytes, :account_id, :inbox_id, :rows, :sha256)

  class InvalidSnapshot < StandardError; end
  class LeaseLost < StandardError; end

  CONTACT_INBOX_FIELDS = %w[created_at hmac_verified pubsub_token updated_at].freeze
  CONTACT_IMMUTABLE_FIELDS = %w[
    account_id blocked company_id contact_type country_code created_at custom_attributes email identifier
    last_activity_at last_name location middle_name phone_number updated_at
  ].freeze
  OPTIONAL_ATTRIBUTE_KEYS = %w[
    social_instagram_follower_count social_instagram_is_user_follow_business
    social_instagram_is_business_follow_user social_instagram_is_verified_user
  ].freeze
  ALLOWED_TOP_LEVEL_KEYS = ['social_instagram_user_name', *OPTIONAL_ATTRIBUTE_KEYS].freeze
  HASH_PATTERN = /\A[0-9a-f]{64}\z/
  MAX_BYTES = 512.megabytes
  MAX_ROWS = 1_000_000
  MAX_LINE_BYTES = 4_096
  BATCH_SIZE = 500
  ALLOWED_BASENAMES = %w[
    fbig-profile-state-v1.tsv
    fbig-profile-clone-prestate-v1.tsv
    fbig-profile-clone-poststate-v1.tsv
    fbig-profile-production-prestate-v1.tsv
    fbig-profile-production-poststate-v1.tsv
  ].freeze

  def self.capture(inbox, renewer: nil)
    checkpoint!(renewer)
    rows = []
    inbox.contact_inboxes.order(:id).find_in_batches(batch_size: BATCH_SIZE) do |batch|
      checkpoint!(renewer)
      batch.each { |contact_inbox| rows << capture_row(inbox, contact_inbox, renewer) }
      checkpoint!(renewer)
    end
    raise InvalidSnapshot if rows.size > MAX_ROWS

    lines = [
      "schema_version\t1",
      "account_id\t#{inbox.account_id}",
      "inbox_id\t#{inbox.id}",
      "row_count\t#{rows.size}",
      *rows.map { |row| row.values.join("\t") }
    ]
    raise InvalidSnapshot if lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    bytes = "#{lines.join("\n")}\n"
    raise InvalidSnapshot if bytes.bytesize > MAX_BYTES

    Artifact.new(
      bytes: bytes,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      rows: rows.freeze,
      sha256: Digest::SHA256.hexdigest(bytes)
    )
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidSnapshot unless text.valid_encoding? && text.end_with?("\n") && text.bytesize <= MAX_BYTES
    raise InvalidSnapshot if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidSnapshot if lines.size < 4 || lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    headers = lines.first(4).map { |line| line.split("\t", -1) }
    expected_names = %w[schema_version account_id inbox_id row_count]
    raise InvalidSnapshot unless headers.map(&:first) == expected_names && headers.all? { |parts| parts.size == 2 }
    raise InvalidSnapshot unless headers.dig(0, 1) == '1'
    raise InvalidSnapshot unless headers.drop(1).all? { |parts| parts.last.match?(/\A(?:0|[1-9][0-9]*)\z/) }

    account_id = Integer(headers.dig(1, 1), 10)
    inbox_id = Integer(headers.dig(2, 1), 10)
    row_count = Integer(headers.dig(3, 1), 10)
    raise InvalidSnapshot if row_count > MAX_ROWS || lines.size != row_count + 4

    rows = lines.drop(4).map { |line| parse_row(line) }
    raise InvalidSnapshot unless rows.map(&:key) == rows.map(&:key).sort
    raise InvalidSnapshot unless rows.map(&:key).uniq.size == rows.size

    Artifact.new(
      bytes: text,
      account_id: account_id,
      inbox_id: inbox_id,
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

  def self.capture_and_seal!(inbox, directory:, basename:, expected_uid: 0, renewer: nil)
    raise InvalidSnapshot unless ALLOWED_BASENAMES.include?(basename)

    directory_path = Pathname.new(directory.to_s)
    verify_directory!(directory_path, expected_uid)
    artifact = capture(inbox, renewer: renewer)
    data_path = directory_path.join(basename)
    checksum_path = directory_path.join("#{basename}.sha256")
    raise InvalidSnapshot if data_path.exist? || checksum_path.exist?

    token = SecureRandom.hex(16)
    temporary_data = directory_path.join(".#{basename}.#{token}.tmp")
    temporary_checksum = directory_path.join(".#{basename}.sha256.#{token}.tmp")
    write_temporary!(temporary_data, artifact.bytes)
    write_temporary!(temporary_checksum, "#{artifact.sha256}  #{basename}\n")
    checkpoint!(renewer)
    File.rename(temporary_data, data_path)
    File.rename(temporary_checksum, checksum_path)
    fsync_directory!(directory_path)
    artifact
  rescue SystemCallError
    raise InvalidSnapshot
  ensure
    [temporary_data, temporary_checksum].compact.each do |path|
      File.unlink(path) if path.exist?
    end
  end

  def self.capture_row(inbox, contact_inbox, renewer)
    contact = Contact.find(contact_inbox.contact_id)
    raise InvalidSnapshot unless contact.account_id == inbox.account_id

    source_id = contact_inbox.source_id.to_s
    additional_attributes = contact.additional_attributes.is_a?(Hash) ? contact.additional_attributes.deep_dup : {}
    values = [
      'contact_inbox',
      contact_inbox.id.to_s,
      Umi::Fbig::TypedValueDigest.hexdigest(source_id),
      contact.id.to_s,
      Umi::Fbig::TypedValueDigest.hexdigest(typed_attributes(contact_inbox, CONTACT_INBOX_FIELDS)),
      Umi::Fbig::TypedValueDigest.hexdigest(typed_attributes(contact, CONTACT_IMMUTABLE_FIELDS)),
      contact.name == "Instagram user #{source_id.last(4)}" ? 'exact_instagram_placeholder' : 'other',
      Umi::Fbig::TypedValueDigest.hexdigest(contact.name.to_s)
    ]
    values.concat(state_pair(additional_attributes.dig('social_profiles', 'instagram'), nested_key_present?(additional_attributes)))
    values.concat(state_pair(additional_attributes['social_instagram_user_name'], additional_attributes.key?('social_instagram_user_name')))
    OPTIONAL_ATTRIBUTE_KEYS.each do |key|
      values.concat(optional_state_pair(additional_attributes[key], additional_attributes.key?(key)))
    end
    values << Umi::Fbig::TypedValueDigest.hexdigest(project_unrelated_attributes(additional_attributes))
    values.concat(avatar_values(contact, renewer))
    Row.new(values: values.freeze)
  rescue Umi::Fbig::TypedValueDigest::UnsupportedValue => e
    raise InvalidSnapshot, e.message
  end
  private_class_method :capture_row

  def self.typed_attributes(record, fields)
    fields.index_with { |field| record.attributes.fetch(field) }
  end
  private_class_method :typed_attributes

  def self.nested_key_present?(attributes)
    profiles = attributes['social_profiles']
    profiles.is_a?(Hash) && profiles.key?('instagram')
  end
  private_class_method :nested_key_present?

  def self.state_pair(value, present)
    return %w[absent -] unless present

    state = value.to_s.strip.empty? ? 'blank' : 'present'
    [state, Umi::Fbig::TypedValueDigest.hexdigest(value)]
  end
  private_class_method :state_pair

  def self.optional_state_pair(value, present)
    return %w[absent -] unless present

    ['present', Umi::Fbig::TypedValueDigest.hexdigest(value)]
  end
  private_class_method :optional_state_pair

  def self.project_unrelated_attributes(attributes)
    projected = attributes.deep_dup
    ALLOWED_TOP_LEVEL_KEYS.each { |key| projected.delete(key) }
    profiles = projected['social_profiles']
    if profiles.is_a?(Hash)
      profiles.delete('instagram')
      projected.delete('social_profiles') if profiles.empty?
    end
    projected
  end
  private_class_method :project_unrelated_attributes

  def self.avatar_values(contact, renewer)
    attachments = ActiveStorage::Attachment.where(name: 'avatar', record_type: 'Contact', record_id: contact.id).to_a
    raise InvalidSnapshot if attachments.many?
    return ['absent', '0', '0', '-', '-', '0'] if attachments.empty?

    attachment = attachments.first
    blob = ActiveStorage::Blob.find(attachment.blob_id)
    metadata = {
      'attachment' => typed_attributes(
        attachment,
        %w[id name record_type record_id blob_id created_at]
      ),
      'blob' => typed_attributes(
        blob,
        %w[id key filename content_type metadata byte_size checksum created_at service_name]
      )
    }
    object_digest = Digest::SHA256.new
    object_size = 0
    checkpoint!(renewer)
    blob.service.download(blob.key) do |chunk|
      object_digest << chunk
      object_size += chunk.bytesize
    end
    checkpoint!(renewer)
    raise InvalidSnapshot unless object_size == blob.byte_size

    [
      'present',
      attachment.id.to_s,
      blob.id.to_s,
      Umi::Fbig::TypedValueDigest.hexdigest(metadata),
      object_digest.hexdigest,
      object_size.to_s
    ]
  rescue ActiveStorage::FileNotFoundError
    raise InvalidSnapshot
  end
  private_class_method :avatar_values

  def self.checkpoint!(renewer)
    raise LeaseLost if renewer && !renewer.call
  rescue LeaseLost
    raise
  rescue StandardError
    raise LeaseLost
  end
  private_class_method :checkpoint!

  def self.parse_row(line)
    values = line.split("\t", -1)
    raise InvalidSnapshot unless values.size == 27 && values.first == 'contact_inbox'
    raise InvalidSnapshot unless [values[1], values[3], values[22], values[23], values[26]].all? do |value|
      value.match?(/\A(?:0|[1-9][0-9]*)\z/)
    end
    raise InvalidSnapshot unless values[1].to_i.positive? && values[3].to_i.positive?

    hash_fields = [2, 4, 5, 7, 20]
    raise InvalidSnapshot unless hash_fields.all? { |index| values[index].match?(HASH_PATTERN) }
    raise InvalidSnapshot unless values[6].in?(%w[exact_instagram_placeholder other])

    validate_state_pair!(values, 8, %w[absent blank present])
    validate_state_pair!(values, 10, %w[absent blank present])
    [12, 14, 16, 18].each { |index| validate_state_pair!(values, index, %w[absent present]) }
    validate_avatar_tuple!(values)
    Row.new(values: values.freeze)
  end
  private_class_method :parse_row

  def self.validate_state_pair!(values, state_index, states)
    state = values[state_index]
    digest = values[state_index + 1]
    raise InvalidSnapshot unless states.include?(state)
    raise InvalidSnapshot unless state == 'absent' ? digest == '-' : digest.match?(HASH_PATTERN)
  end
  private_class_method :validate_state_pair!

  def self.validate_avatar_tuple!(values)
    if values[21] == 'absent'
      raise InvalidSnapshot unless values.values_at(22, 23, 24, 25, 26) == %w[0 0 - - 0]
    elsif values[21] == 'present'
      valid = values[22].to_i.positive? &&
              values[23].to_i.positive? &&
              values[24].match?(HASH_PATTERN) &&
              values[25].match?(HASH_PATTERN)
      raise InvalidSnapshot unless valid
    else
      raise InvalidSnapshot
    end
  end
  private_class_method :validate_avatar_tuple!

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

  def self.write_temporary!(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
    File.chmod(0o400, path)
  end
  private_class_method :write_temporary!

  def self.fsync_directory!(directory)
    File.open(directory, File::RDONLY, &:fsync)
  end
  private_class_method :fsync_directory!
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity
