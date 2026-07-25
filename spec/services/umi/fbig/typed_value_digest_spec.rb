require 'rails_helper'

RSpec.describe Umi::Fbig::TypedValueDigest do
  it 'keeps nil, false, zero, and blank string byte-distinct' do
    digests = [nil, false, 0, ''].map { |value| described_class.hexdigest(value) }

    expect(digests.uniq.size).to eq(4)
    expect(digests).to eq(
      %w[
        6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d
        4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a
        0eecaee0239c370f79aa7e9276b7cf17bc6414a33229ca2a286b3973ff6ef85c
        6c449f91c1adbf3945ad078f5f875c0c1f133f246c4588668faffbe23a3c195f
      ]
    )
  end

  it 'sorts string-keyed hashes by UTF-8 bytes and retains array order' do
    forward = described_class.hexdigest('b' => [1, 2], 'a' => true)
    reverse = described_class.hexdigest('a' => true, 'b' => [1, 2])
    reordered_array = described_class.hexdigest('a' => true, 'b' => [2, 1])

    expect(forward).to eq(reverse)
    expect(reordered_array).not_to eq(forward)
  end

  it 'rejects unsupported values, non-string keys, invalid UTF-8, and non-finite doubles' do
    invalid_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)

    [Object.new, { 1 => 'value' }, invalid_utf8, Float::INFINITY, Float::NAN].each do |value|
      expect { described_class.hexdigest(value) }.to raise_error(described_class::UnsupportedValue)
    end
  end
end
