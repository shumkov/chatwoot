# UMI Facebook/Instagram history migration record

Status: **completed and retired** on 2026-08-01. The one-time importer, profile
runner, approval machinery, and executable runbook were removed after the
production operation. Do not infer that these are supported maintenance tools
or reconstruct and rerun them from Git history without a new reviewed plan.

## Production identity

- Rails and Sidekiq commit: `7570ec0489bb6d79cbb012f36a6d8f0b8957b82e`
- Rails and Sidekiq image:
  `sha256:507e113873ca4b560921cccf5777ea4753d186556614bb23158356b801c3b33a`
- Fixed history cutoff: `2026-07-28T15:39:00Z`

The bounded profile completion work restored and verified this exact release.
No application release change remained after the operation.

## Imported history

| Platform | Created archives | Imported messages |
|---|---:|---:|
| Messenger | 52 | 633 |
| Instagram | 607 | 8,408 |

The Instagram total includes a successor pass that scanned all 681 Meta
threads and added four pre-cutoff historical messages (three incoming and one
outgoing) plus three attachments. It added no contacts, contact-inbox rows,
archives, profile changes, activity, or configuration.

That successor was accepted as an explicit writeful terminal exception. Its
preserved result remained:

- `require_zero_writes=true`
- `exit_status=1`
- `termination=normal`
- `counter_mismatches=zero_write_required`
- `zero_write_observed=false`
- `contentless_acceptance_mismatches=1`
- `exit_failures=1`
- `write_complete=false`
- observed contentless fingerprint:
  `f54ee8f9b46ba5e149dd98b8438cbf409e91cff87db8ba09f1d64445ceb31c56`

No Instagram successor-2 or later convergence scan was run. Therefore 8,408 is
the accepted production observation, not a claim that a later zero-write Meta
scan proved convergence.

## Profile completion

The final bounded profile pass covered seven sealed targets. Six were fixed;
one remained unavailable from Meta. After the pass, 493 contacts in the
marker-selected set had an avatar. The temporary direct runner relaxed only
the obsolete migration configuration-equality gate; it did not list or fetch
message history and did not create or modify history rows. Its source and
result are retained only in the root-owned completion evidence.

## Full imported-conversation read-state audit

The final audit selected every conversation for which
`jsonb_exists(additional_attributes, 'umi_history_import')` was true. It was
not a sample and did not include unrelated native conversations.

| Platform | Total | Unread | Not resolved |
|---|---:|---:|---:|
| Messenger | 68 | 0 | 0 |
| Instagram | 613 | 0 | 0 |
| **All imported markers** | **681** | **0** | **0** |

For this audit, unread meant `agent_last_seen_at < last_activity_at`. Every one
of the 681 selected conversations had `status=resolved` and
`agent_last_seen_at >= last_activity_at`. There were zero unsupported
platforms, zero null `last_activity_at` values, and zero read-state repairs.

Six legacy rows had malformed marker/configuration or marker/identifier
ownership exceptions. They remained inside the full 681-row selection and
satisfied the same resolved/read predicate. They were not rewritten because
the authorized repair scope covered only exact imported archives that failed
read state.

## Sealed evidence

- Completion root:
  `/opt/umi/fbig-ops/profile-completion-20260801T060110Z`
- Completion evidence JSON SHA-256:
  `d87c6556420de482426a355f4dc24f0b3cfd21203d3ebfedb03803f5e223fe68`
- Completion manifest SHA-256:
  `4ec2a4df2bba39f4c4ec9a245a17a6ad61239adb1c7d96f9bd76a259a14a8a2b`
- Writeful Instagram successor evidence:
  `/opt/umi/fbig-history-attempts/.instagram-successor-1.in-progress`
- Preserved comparator output SHA-256:
  `fcac46451a01d53114f73feedec6a425929df99ca5a64a4529655e3f1518078c`

The production evidence is root-owned and contains the detailed audit trail.
This repository record intentionally contains only aggregate outcomes,
release identities, non-secret evidence locators, and checksums—no raw logs,
tokens, names, handles, contact/message/account identifiers, URLs, or backup
contents.

## Durable code retained

The migration left one generally useful database safeguard: the partial
unique Active Storage index that permits at most one `avatar` attachment for a
`Contact`. Its migration, schema entry, and regression coverage remain because
ordinary live and reconciliation-heal writers still attach Contact avatars.
It is independently registered as active UMI patch 17.

The daily FB/IG reconciliation, optional inbound auto-heal, attachment
resilience, fallback contact, participant-name fallback, and trace patches are
ongoing runtime behavior independent of the retired migration.

Before deploying the cleanup release, verify that no old importer process or
queued importer task is active. The cleanup image removes the importer and its
healer lock together; sealed historical programs are evidence, not supported
runtime inputs.
