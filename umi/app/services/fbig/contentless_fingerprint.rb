# frozen_string_literal: true

require 'digest'

class Umi::Fbig::ContentlessFingerprint
  Result = Data.define(:count, :fingerprint)

  class DuplicateMidError < StandardError; end
  class InvalidEncodingError < StandardError; end

  PLATFORMS = %w[messenger instagram].freeze

  def self.build(platform:, mids:)
    raise ArgumentError, 'unsupported platform' unless PLATFORMS.include?(platform)

    normalized_mids = Array(mids).map { |mid| utf8_bytes(mid) }
    raise DuplicateMidError if normalized_mids.uniq.size != normalized_mids.size

    digest = Digest::SHA256.new
    [platform.b, *normalized_mids.sort].each do |value|
      digest << [value.bytesize].pack('Q>') << value
    end

    Result.new(count: normalized_mids.size, fingerprint: digest.hexdigest)
  end

  def self.utf8_bytes(value)
    string = value.to_s
    raise InvalidEncodingError unless string.encoding == Encoding::UTF_8 && string.valid_encoding?

    string.b
  end
  private_class_method :utf8_bytes
end
