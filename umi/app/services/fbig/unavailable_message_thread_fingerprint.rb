# frozen_string_literal: true

class Umi::Fbig::UnavailableMessageThreadFingerprint
  Result = Data.define(:count, :fingerprint)

  class DuplicateThreadIdError < StandardError; end
  class InvalidRecordError < StandardError; end

  PLATFORMS = %w[messenger instagram].freeze
  RECORD_FIELDS = %w[
    thread_id external_participant_id archive_present http_status error_code error_subcode error_type
  ].freeze
  ERROR_FIELDS = %w[http_status error_code error_subcode error_type].freeze
  ERROR_VALUES = {
    'http_status' => 400,
    'error_code' => -1,
    'error_subcode' => 2_207_085,
    'error_type' => 'OAuthException'
  }.freeze

  def self.build(platform:, records:)
    validate_platform!(platform)
    normalized = Array(records).map { |record| normalize_record(record) }
    validate_records!(platform, normalized)
    value = {
      'domain' => 'umi-fbig-unavailable-message-threads-v1',
      'platform' => platform,
      'threads' => normalized.sort_by { |record| record.fetch('thread_id').b }
    }
    Result.new(count: normalized.size, fingerprint: Umi::Fbig::TypedValueDigest.hexdigest(value))
  end

  def self.validate_platform!(platform)
    raise ArgumentError, 'unsupported platform' unless PLATFORMS.include?(platform)
  end
  private_class_method :validate_platform!

  def self.validate_records!(platform, records)
    raise InvalidRecordError if platform == 'messenger' && records.present?

    thread_ids = records.pluck('thread_id').map(&:b)
    raise DuplicateThreadIdError if thread_ids.uniq.size != thread_ids.size
  end
  private_class_method :validate_records!

  def self.normalize_record(record)
    validate_record_shape!(record)
    validate_record_identity!(record)
    raise InvalidRecordError unless record.slice(*ERROR_FIELDS) == ERROR_VALUES

    record.transform_values { |value| value.is_a?(String) ? value.encode(Encoding::UTF_8) : value }
  rescue ArgumentError, KeyError
    raise InvalidRecordError
  end
  private_class_method :normalize_record

  def self.validate_record_shape!(record)
    raise InvalidRecordError unless record.is_a?(Hash) && record.keys.sort == RECORD_FIELDS.sort
  end
  private_class_method :validate_record_shape!

  def self.validate_record_identity!(record)
    %w[thread_id external_participant_id].each do |field|
      raise InvalidRecordError unless valid_identifier?(record.fetch(field))
    end
    raise InvalidRecordError unless [true, false].include?(record.fetch('archive_present'))
  end
  private_class_method :validate_record_identity!

  def self.valid_identifier?(value)
    value.is_a?(String) &&
      value.valid_encoding? &&
      value.encoding.in?([Encoding::UTF_8, Encoding::US_ASCII]) &&
      value.present?
  end
  private_class_method :valid_identifier?
end
