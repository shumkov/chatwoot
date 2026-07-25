# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProfileStateComparator
  Result = Data.define(:eligible_counts, :protected_changes, :counter_mismatches) do
    def success?
      protected_changes.zero? && counter_mismatches.zero?
    end
  end

  BLANK_NAME_DIGEST = Umi::Fbig::TypedValueDigest.hexdigest('')

  def self.compare(before:, after:, applied_counters:, enforce_counters: true)
    before_rows = before.rows.index_by(&:key)
    after_rows = after.rows.index_by(&:key)
    counts = { name: 0, username: 0, optional: 0, avatar: 0 }
    protected_changes = 0
    if before.account_id != after.account_id || before.inbox_id != after.inbox_id || before_rows.keys != after_rows.keys
      protected_changes += 1
    else
      before_rows.each do |key, before_row|
        protected_changes += compare_row(before_row.values, after_rows.fetch(key).values, counts)
      end
    end
    expected = counts.transform_values(&:to_i)
    supplied = expected.keys.index_with { |key| applied_counters.fetch(key, 0).to_i }
    Result.new(
      eligible_counts: expected,
      protected_changes: protected_changes,
      counter_mismatches: !enforce_counters || expected == supplied ? 0 : 1
    )
  end

  def self.compare_row(before, after, counts)
    protected = 0
    protected += 1 unless [*0..5, 20].all? { |index| before[index] == after[index] }

    if before.values_at(6, 7) != after.values_at(6, 7)
      if before[6] == 'exact_instagram_placeholder' && after[6] == 'other' && after[7] != BLANK_NAME_DIGEST
        counts[:name] += 1
      else
        protected += 1
      end
    end
    [8, 10].each do |index|
      next if before.values_at(index, index + 1) == after.values_at(index, index + 1)

      if before[index].in?(%w[absent blank]) && after[index] == 'present'
        counts[:username] += 1
      else
        protected += 1
      end
    end
    [12, 14, 16, 18].each do |index|
      next if before.values_at(index, index + 1) == after.values_at(index, index + 1)

      if before[index] == 'absent' && after[index] == 'present'
        counts[:optional] += 1
      else
        protected += 1
      end
    end
    if before.values_at(21, 22, 23, 24, 25, 26) != after.values_at(21, 22, 23, 24, 25, 26)
      if before[21] == 'absent' && after[21] == 'present'
        counts[:avatar] += 1
      else
        protected += 1
      end
    end
    protected
  end
  private_class_method :compare_row
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
