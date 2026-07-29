# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
class Umi::Fbig::ProfileRunEvidence
  Result = Data.define(:prestate, :poststate, :staging, :comparison, :reconciliation)

  class InvalidEvidence < StandardError; end
  class LeaseLost < StandardError; end

  def initialize(inbox:, mode:, source_state:, attempt_directory:, intent_store:, clone_phase: nil,
                 predecessor_state: nil, expected_uid: 0)
    raise InvalidEvidence unless mode.in?(%w[clone_evidence production production_first])
    raise InvalidEvidence if mode == 'clone_evidence' && source_state.nil?
    raise InvalidEvidence if mode == 'production' && source_state
    raise InvalidEvidence if mode == 'production_first' && source_state.nil?

    if mode == 'clone_evidence'
      raise InvalidEvidence unless clone_phase.in?(%w[dry apply idempotency])
      raise InvalidEvidence if clone_phase == 'idempotency' ? predecessor_state.nil? : predecessor_state
    elsif mode == 'production_first'
      raise InvalidEvidence if clone_phase
    elsif clone_phase || predecessor_state
      raise InvalidEvidence
    end

    @inbox = inbox
    @mode = mode
    @source_state = source_state
    @clone_phase = clone_phase
    @predecessor_state = predecessor_state
    @attempt_directory = attempt_directory
    @intent_store = intent_store
    @expected_uid = expected_uid
  end

  def start!(renewer:)
    raise InvalidEvidence if @started

    basename = production_mode? ? 'fbig-profile-production-prestate-v1.tsv' : 'fbig-profile-clone-prestate-v1.tsv'
    @run_prestate = Umi::Fbig::ProfileStateSnapshot.capture_and_seal!(
      @inbox,
      directory: @attempt_directory,
      basename: basename,
      expected_uid: @expected_uid,
      renewer: renewer
    )
    validate_clone_lineage! if @mode == 'clone_evidence'
    validate_production_first_source! if @mode == 'production_first'
    @staging_source_sha256 = production_mode? ? @run_prestate.sha256 : @source_state.sha256
    @started = true
    @run_prestate
  rescue Umi::Fbig::ProfileStateSnapshot::LeaseLost
    raise LeaseLost
  end

  def finish!(stats:, dry_run:, renewer:)
    raise InvalidEvidence unless @started && !@finished

    renew!(renewer)
    reconciliation = @intent_store.reconcile!(renewer: renewer)
    renew!(renewer)
    staging = Umi::Fbig::AvatarStagingManifest.seal!(
      directory: @attempt_directory,
      source_state_sha256: @staging_source_sha256,
      entries: reconciliation.entries,
      expected_uid: @expected_uid
    )
    renew!(renewer)
    poststate = capture_poststate(renewer)
    validate_staging_against_poststate!(staging, poststate)
    comparison = Umi::Fbig::ProfileStateComparator.compare(
      before: @run_prestate,
      after: poststate,
      applied_counters: applied_counters(stats, dry_run)
    )
    raise InvalidEvidence unless comparison.success?

    @finished = true
    Result.new(
      prestate: @run_prestate,
      poststate: poststate,
      staging: staging,
      comparison: comparison,
      reconciliation: reconciliation
    )
  rescue Umi::Fbig::ProfileStateSnapshot::LeaseLost,
         Umi::Fbig::AvatarIntentStore::LeaseLost
    raise LeaseLost
  end

  private

  def production_mode?
    @mode.in?(%w[production production_first])
  end

  def validate_clone_lineage!
    if @clone_phase.in?(%w[dry apply])
      raise InvalidEvidence unless @source_state.sha256 == @run_prestate.sha256

      return
    end

    raise InvalidEvidence unless @predecessor_state.sha256 == @run_prestate.sha256

    comparison = Umi::Fbig::ProfileStateComparator.compare(
      before: @source_state,
      after: @predecessor_state,
      applied_counters: {},
      enforce_counters: false
    )
    raise InvalidEvidence unless comparison.success?
  end

  def validate_production_first_source!
    if @predecessor_state
      raise InvalidEvidence unless @predecessor_state.sha256 == @run_prestate.sha256

      comparison = Umi::Fbig::ProfileStateComparator.compare(
        before: @source_state,
        after: @predecessor_state,
        applied_counters: {},
        enforce_counters: false
      )
      raise InvalidEvidence unless comparison.success?

      return
    end

    comparison = Umi::Fbig::ProfileStateComparator.compare(
      before: @source_state,
      after: @run_prestate,
      applied_counters: {},
      enforce_counters: false
    )
    raise InvalidEvidence unless comparison.success? && comparison.eligible_counts.values.all?(&:zero?)
  end

  def capture_poststate(renewer)
    if @mode == 'clone_evidence'
      return Umi::Fbig::ProfileStateSnapshot.capture_and_seal!(
        @inbox,
        directory: @attempt_directory,
        basename: 'fbig-profile-clone-poststate-v1.tsv',
        expected_uid: @expected_uid,
        renewer: renewer
      )
    end

    Umi::Fbig::ProfileStateSnapshot.capture_and_seal!(
      @inbox,
      directory: @attempt_directory,
      basename: 'fbig-profile-production-poststate-v1.tsv',
      expected_uid: @expected_uid,
      renewer: renewer
    )
  end

  def applied_counters(stats, dry_run)
    return { name: 0, username: 0, optional: 0, avatar: 0 } if dry_run

    {
      name: stats.fetch(:name_changes_applied, 0),
      username: stats.fetch(:username_changes_applied, 0),
      optional: stats.fetch(:optional_changes_applied, 0),
      avatar: stats.fetch(:avatars_attached, 0)
    }
  end

  def validate_staging_against_poststate!(staging, poststate)
    rows = poststate.rows.index_by(&:key)
    staging.entries.select { |entry| entry.outcome == 'attached' }.each do |entry|
      row = rows[[entry.contact_inbox_id, entry.source_id_sha256]]
      valid = row &&
              row.values[21] == 'present' &&
              row.values[22] == entry.attachment_id.to_s &&
              row.values[23] == entry.blob_id.to_s &&
              row.values[25] == entry.object_sha256
      raise InvalidEvidence unless valid
    end
  end

  def renew!(renewer)
    raise LeaseLost unless renewer.call
  rescue LeaseLost
    raise
  rescue StandardError
    raise LeaseLost
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
