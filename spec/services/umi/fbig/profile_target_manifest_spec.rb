require 'rails_helper'
require 'tmpdir'

RSpec.describe Umi::Fbig::ProfileTargetManifest do
  let(:seven_rows) do
    (1..7).map { |id| "#{id}\t#{id + 10}\t#{id + 100}\n" }.join
  end

  it 'parses every snapshot-bound row instead of the former six-row release constant' do
    rows = described_class.parse(seven_rows)

    expect(rows.size).to eq(7)
    expect(rows.first).to have_attributes(contact_inbox_id: 1, contact_id: 11, source_id: '101')
  end

  it 'accepts a second positive row count so changing six to seven cannot satisfy the contract' do
    rows = described_class.parse("1\t11\t101\n2\t12\t102\n")

    expect(rows.size).to eq(2)
  end

  it 'rejects empty, reordered, duplicate, malformed, or noncanonical rows' do
    invalid = [
      '',
      seven_rows.lines.reverse.join,
      seven_rows.sub("2\t12\t102", "1\t12\t102"),
      seven_rows.sub("2\t12\t102", "2\t12\t101"),
      seven_rows.sub("2\t12\t102", "02\t12\t102"),
      seven_rows.delete_suffix("\n")
    ]

    invalid.each do |value|
      expect { described_class.parse(value) }.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'accepts the exact row, line, and file-size maxima' do
    bytes = (1..described_class::MAX_ROWS).map do |id|
      prefix = "#{id}\t#{id + described_class::MAX_ROWS}\t#{id}"
      "#{prefix}#{'9' * (described_class::MAX_LINE_BYTES - prefix.bytesize - 1)}\n"
    end.join

    expect(bytes.bytesize).to eq(described_class::MAX_BYTES)
    expect(bytes.lines).to all(satisfy { |line| line.bytesize == described_class::MAX_LINE_BYTES })
    expect(described_class.parse(bytes).size).to eq(described_class::MAX_ROWS)
  end

  it 'rejects maximum-plus-one rows and an oversized line' do
    too_many_rows = (1..(described_class::MAX_ROWS + 1)).map do |id|
      "#{id}\t#{id + described_class::MAX_ROWS + 1}\t#{id + 100_000}\n"
    end.join
    oversized_line = "1\t1\t#{'9' * 252}\n"

    expect(oversized_line.bytesize).to eq(described_class::MAX_LINE_BYTES + 1)
    expect { described_class.parse(too_many_rows) }.to raise_error(described_class::InvalidManifest)
    expect { described_class.parse(oversized_line) }.to raise_error(described_class::InvalidManifest)
  end

  it 'loads the fixed, locked sidecar only when its bound digest matches' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'fbig-profile-targets-v1.tsv')
      File.binwrite(path, seven_rows)
      File.chmod(0o700, directory)
      File.chmod(0o400, path)

      rows = described_class.load(
        path: path,
        expected_sha256: Digest::SHA256.hexdigest(seven_rows),
        expected_uid: Process.uid
      )

      expect(rows.size).to eq(7)
      expect do
        described_class.load(path: path, expected_sha256: '0' * 64, expected_uid: Process.uid)
      end.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'rejects an oversized file through the bounded loader' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'fbig-profile-targets-v1.tsv')
      bytes = "1\t1\t#{'9' * described_class::MAX_BYTES}\n"
      File.binwrite(path, bytes)
      File.chmod(0o700, directory)
      File.chmod(0o400, path)

      expect do
        described_class.load(
          path: path,
          expected_sha256: Digest::SHA256.hexdigest(bytes),
          expected_uid: Process.uid
        )
      end.to raise_error(described_class::InvalidManifest)
    end
  end
end
