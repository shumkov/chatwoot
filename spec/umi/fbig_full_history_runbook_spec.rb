# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'UMI FB/IG full-history runbook' do
  let(:runbook) { File.read(File.expand_path('../../docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md', __dir__)) }

  it 'uses portable awk field variables in every summary parser' do
    expect(runbook).not_to include('for (index =')
    expect(runbook.scan('for (field =')).not_to be_empty
  end

  it 'binds the exact unrecoverable Instagram envelope into the accepted approval chain' do
    expect(runbook).to include('fbig-unrecoverable-envelope-v1.tsv')
    expect(runbook).to include('umi-fbig-unrecoverable-envelope-v1')
    expect(runbook).to include('source_dry_log_sha256')
    expect(runbook).to include('inspector_script_sha256')
  end

  it 'refuses to fingerprint an ambiguous envelope that has become recoverable' do
    inspector = runbook.match(
      /UNRECOVERABLE_INSPECTOR=.*?<<'RUBY'\n(?<body>.*?)\nRUBY/m
    )[:body]

    expect(inspector).to include(
      "abort('unrecoverable envelope participant shape changed')",
      "abort('unrecoverable envelope message shape changed')",
      "participants_state == 'array'",
      "participants == [{ 'id' => business_id, 'business' => true }]",
      'messages.size == 1',
      "message.fetch('listing_sender') == business_id",
      "message.fetch('detail_sender') == business_id",
      "message.fetch('recipients').empty?",
      "message.fetch('message_blank')",
      "message.fetch('attachment_descriptors').zero?",
      "message.fetch('attachment_omissions').empty?"
    )
    ordered_markers = [
      "abort('unrecoverable envelope participant shape changed')",
      "abort('unrecoverable envelope message shape changed')",
      'ambiguous_threads <<',
      'TypedValueDigest.hexdigest(record)',
      "puts [\n  '[UMI-FBIG]'"
    ]
    positions = ordered_markers.map { |marker| inspector.index(marker) }

    expect(positions).to all(be_a(Integer))
    expect(positions).to eq(positions.sort)
  end

  it 'brackets every Instagram-inclusive clone and production history run with exact envelope checks' do
    expect(runbook).to match(
      /
        inspect_unrecoverable_envelopes\ before-probe .*?
        PLATFORMS=messenger,instagram .*? umi:fbig:history_import .*?
        inspect_unrecoverable_envelopes\ after-probe
      /mx
    )
    expect(runbook).to match(
      /
        accepted_history_dry_run\(\) .*?
        inspect_unrecoverable_envelopes\ "before-\$attempt" .*?
        history_run\ true\ messenger,instagram .*?
        inspect_unrecoverable_envelopes\ "after-\$attempt" .*? ^\}
      /mx
    )
    expect(runbook).to match(
      /
        history_apply_with_verification\(\) .*?
        inspect_unrecoverable_envelopes\ "before-\$label" .*?
        history_run\ false\ "\$platforms" .*?
        inspect_unrecoverable_envelopes\ "after-\$label" .*? ^\}
      /mx
    )
    expect(runbook).to match(
      /
        production_history_run_with_verification\(\) .*?
        inspect_production_unrecoverable_envelopes\ "before-\$label" .*?
        fbig_history_run\.sh .*?
        inspect_production_unrecoverable_envelopes\ "after-\$label" .*? ^\}
      /mx
    )
    expect(runbook).to include('inspect_production_unrecoverable_envelopes final-production')
  end

  it 'validates the strict exception sidecar and chains it into production approval' do
    production = runbook.match(/## 9\. Production history\n(?<body>.*?)(?=^## 10\.)/m)[:body]
    ordered_markers = [
      'sha256sum --check "$(basename "$UNRECOVERABLE_SIDECAR_CHECKSUM")"',
      'EXPECTED_UNRECOVERABLE_FIELDS=(',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" repository_commit)" = "$APP_COMMIT"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" image_digest)" = "$APP_DIGEST"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" before)" = "$CUTOFF"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" inspector_script_sha256)" =',
      'test "$(manifest_value "$HISTORY_APPROVAL" source_dry_log_sha256)" =',
      '"$(sha256_file "$HISTORY_PROBE_LOG")"',
      'stage=unrecoverable_envelope_approval sidecar_sha256=',
      'production_history_run_with_verification()'
    ]
    positions = ordered_markers.map { |marker| production.index(marker) }

    expect(positions).to all(be_a(Integer))
    expect(positions).to eq(positions.sort)
  end
end
# rubocop:enable RSpec/DescribeClass
