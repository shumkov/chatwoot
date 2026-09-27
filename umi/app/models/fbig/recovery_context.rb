# frozen_string_literal: true

# Scoped to synchronous replay so live webhook payloads cannot supply recovery
# provenance. Matching the inbox and source prevents unrelated writes in the
# same execution context from inheriting it.
class Umi::Fbig::RecoveryContext < ActiveSupport::CurrentAttributes
  attribute :inbox_id, :source_id, :source_created_at
end
