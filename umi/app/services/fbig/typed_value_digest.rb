# frozen_string_literal: true

require 'digest'

# The symbolic tags are protocol constants, not boolean values or view helpers.
# rubocop:disable Lint/BooleanSymbol, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Rails/ContentTag
class Umi::Fbig::TypedValueDigest
  class UnsupportedValue < StandardError; end

  TAGS = {
    nil: 0x00,
    false: 0x01,
    true: 0x02,
    integer: 0x03,
    double: 0x04,
    string: 0x05,
    timestamp: 0x06,
    array: 0x07,
    hash: 0x08
  }.freeze

  def self.hexdigest(value)
    Digest::SHA256.hexdigest(encode(value))
  end

  def self.encode(value)
    case value
    when nil
      tag(:nil)
    when false
      tag(:false)
    when true
      tag(:true)
    when Integer
      tag(:integer) << framed(value.to_s.b)
    when Float
      raise UnsupportedValue unless value.finite?

      tag(:double) << [value].pack('G')
    when String
      tag(:string) << framed(utf8_bytes(value))
    when Time, ActiveSupport::TimeWithZone
      tag(:timestamp) << framed(value.utc.iso8601(6).b)
    when Array
      tag(:array) << [value.size].pack('Q>') << value.map { |item| encode(item) }.join
    when Hash
      encode_hash(value)
    else
      raise UnsupportedValue
    end
  end

  def self.encode_hash(value)
    raise UnsupportedValue unless value.keys.all?(String)

    keys = value.keys.map { |key| [key, utf8_bytes(key)] }.sort_by(&:last)
    tag(:hash) << [keys.size].pack('Q>') << keys.map do |key, bytes|
      framed(bytes) << encode(value.fetch(key))
    end.join
  end
  private_class_method :encode_hash

  def self.tag(name)
    [TAGS.fetch(name)].pack('C')
  end
  private_class_method :tag

  def self.framed(bytes)
    [bytes.bytesize].pack('Q>') << bytes
  end
  private_class_method :framed

  def self.utf8_bytes(value)
    valid_encoding = value.valid_encoding? && value.encoding.in?([Encoding::UTF_8, Encoding::US_ASCII])
    raise UnsupportedValue, "string is not valid UTF-8 (#{value.encoding.name})" unless valid_encoding

    value.encode(Encoding::UTF_8).b
  end
  private_class_method :utf8_bytes
end
# rubocop:enable Lint/BooleanSymbol, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Rails/ContentTag
