# frozen_string_literal: true

# Append-only record of every contact attribute the profile refresher rewrites.
#
# Contact carries no audit trail — it is absent from the enterprise audit model
# list, there is no paper_trail, and the only other recovery is a pg_dump
# restore that would roll back every message since. So without this, a wrong
# rename is unrecoverable.
#
# Holds customer names and Instagram handles, so it is a PII store and is
# swept on every run: past the retention window, orphaned by a deleted
# contact, or belonging to a contact whose erasure was requested. Sweeping
# from the job rather than a Contact callback keeps the cleanup in one place
# and avoids patching a core model.
class Umi::ProfileLedgerEntry < ApplicationRecord
  self.table_name = 'umi_profile_ledger_entries'

  RETENTION = 90.days

  # Revert is only meaningful against the first pass, where old_value is
  # pre-patch truth; on later cycles it is merely the previous machine write
  # and there is no anchor to "the correct name".
  scope :for_run, ->(run_id) { where(run_id: run_id) }

  def self.sweep!
    expired = where(created_at: ...RETENTION.ago).delete_all
    orphaned = where.not(contact_id: Contact.select(:id)).delete_all
    redacted = where(contact_id: Contact.where("additional_attributes->>'umi_profile_redacted' = 'true'").select(:id)).delete_all
    { expired: expired, orphaned: orphaned, redacted: redacted }
  end
end
