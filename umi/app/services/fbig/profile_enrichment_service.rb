# frozen_string_literal: true

# Fills in the name, handle and avatar that Meta withheld when a contact was
# first created.
#
# Chatwoot fetches a Meta profile exactly once, at contact creation, and never
# looks again — ContactInboxWithContactBuilder returns early on an existing
# contact_inbox, and the Instagram path gates on contacts_first_message?. So
# every contact created while Meta was denying the profile API keeps its
# placeholder name and missing avatar forever.
#
# Design, probe evidence and the rejected alternatives are in
# docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md.
class Umi::Fbig::ProfileEnrichmentService
  # ContactInboxWithContactBuilder#contact_name falls back to this shape when
  # no name is supplied (adjective-noun-N).
  HAIKUNATOR_NAME = /\A[a-z]+-[a-z]+-\d{1,4}\z/
  # 'John Doe' is upstream's Facebook placeholder; 'Facebook user' came from
  # the retired history importer. The per-component variants ("Somchai Doe")
  # that messages/facebook/message_builder.rb can mint are deliberately NOT
  # rewritable: none exist in production, and a rule matching them would also
  # match a customer genuinely named "Jane Doe".
  REWRITABLE_LITERALS = ['John Doe', 'Facebook user'].freeze
  MAX_AVATAR_BYTES = 15.megabytes
  # Freshness stamp for the Business Discovery pass. Separate from
  # umi_profile_checked_at because the two passes have separate budgets and
  # separate queues; sharing one stamp would let either starve the other.
  DISCOVERY_STAMP = 'umi_business_discovery_at'

  Outcome = Struct.new(:status, :name, :avatar, :error, keyword_init: true)
  Resolution = Struct.new(:name, :source, :handle, :avatar_url, :extra, keyword_init: true)

  def initialize(channel, run_id:, apply: false)
    @channel = channel
    @run_id = run_id
    @apply = apply
  end

  def enrich(contact)
    @graph_error = false
    contact_inbox = sole_contact_inbox(contact)
    return Outcome.new(status: :skipped) if contact_inbox.nil?
    return Outcome.new(status: :redacted) if contact.additional_attributes['umi_profile_redacted']

    resolve_and_write(contact, contact_inbox)
  rescue Koala::Facebook::AuthenticationError
    # A 401 is not transient. Let the caller stand the whole run down rather
    # than hammering Meta once per contact.
    raise
  rescue StandardError => e
    Umi::FbigTrace.log(:profile_failed, contact: contact.id, reason: e.class.name)
    Outcome.new(status: :failed, error: e)
  end

  # The write half of this service, public so Business Discovery — which
  # resolves the same facts through a different Meta endpoint — reaches the
  # same gates instead of reimplementing them. The rename claim, the ledger,
  # the avatar uniqueness handling and the erasure re-check are the whole
  # safety story here; a second copy of them is the failure mode to avoid.
  def apply_resolution(contact, contact_inbox, resolution)
    renaming = resolution.name.present? && resolution.name != contact.name
    return preview(resolution, renaming) unless @apply

    attached = apply_avatar(contact, contact_inbox, resolution)
    apply_name(contact, contact_inbox, resolution, renaming: renaming, attached: attached)
    # Projection last, and unconditionally: the commercial fields have been
    # arriving into additional_attributes for months on contacts this pass
    # otherwise leaves alone, and nothing reads them until they are copied
    # across. Costs no API call.
    Umi::Meta::InstagramProfileAttributes.project!(contact)

    Outcome.new(status: (renaming || attached ? :updated : :unchanged), name: resolution.name,
                avatar: (resolution.avatar_url if attached))
  end

  # Once we have written a name, that exact string is our claim on it: an agent
  # who edits it breaks the equality and we never touch the contact again.
  # Before any write exists, only the known placeholder shapes are fair game —
  # matched against THIS contact_inbox's source_id, because a contact can own
  # several across both platforms.
  def rename_allowed?(contact, contact_inbox)
    written = contact.additional_attributes['umi_profile_name']
    return contact.name == written if written.present?

    name = contact.name.to_s
    name == "Instagram user #{contact_inbox.source_id.to_s.last(4)}" ||
      REWRITABLE_LITERALS.include?(name) ||
      name.match?(HAIKUNATOR_NAME) ||
      # Still ours even if the stamp was lost to a concurrent whole-column
      # write, which would otherwise freeze the contact on its handle forever.
      name == contact.additional_attributes['social_instagram_user_name']
  end

  # Records a freshness stamp on its own. Deliberately does not stamp
  # umi_profile_checked_at: that drives the other pass's queue, and a contact
  # Business Discovery could not answer for has not been profile-checked.
  def stamp(contact, attributes)
    return unless @apply

    merge_attributes(contact, name: nil, handle: nil, succeeded: false, extra: attributes)
  end

  # A merge can move several contact_inboxes onto one contact. Which Meta
  # identity the contact "is" is then genuinely ambiguous, and picking one
  # would write another customer's handle onto it.
  def sole_contact_inbox(contact)
    contact_inboxes = contact.contact_inboxes.where(inbox_id: inbox.id).order(:id).to_a
    return nil if contact_inboxes.empty?
    return contact_inboxes.first if contact_inboxes.one?

    Umi::FbigTrace.log(:profile_ambiguous, contact: contact.id, contact_inboxes: contact_inboxes.size)
    nil
  end

  private

  def inbox
    @inbox ||= @channel.inbox
  end

  def resolve_and_write(contact, contact_inbox)
    profile = profile_for(contact, contact_inbox)
    platform = Umi::Fbig::PlatformResolver.for(contact_inbox, profile)
    name, source = resolve_name(contact, contact_inbox, platform, profile)
    avatar_url = (profile['profile_pic'].presence unless contact.avatar.attached?)

    # Meta refused and told us nothing. Report it as a failure and, crucially,
    # do NOT stamp checked_at: a throttled contact must stay at the front of
    # the queue, not sort to the back for a whole cycle looking healthy.
    return Outcome.new(status: :failed) if @graph_error && name.nil? && avatar_url.nil?

    apply_resolution(contact, contact_inbox, Resolution.new(
                                               name: name, source: source,
                                               handle: handle_from(profile, platform, name, source),
                                               avatar_url: avatar_url
                                             ))
  end

  # An Instagram participants lookup answers with the handle, not a display
  # name — that is all the endpoint carries for this platform. Storing it as
  # the handle as well as the name is what lets Business Discovery reach the
  # contact later without paying for the lookup a second time.
  def handle_from(profile, platform, name, source)
    return profile['username'].presence if profile['username'].present?
    return nil unless platform == :instagram && source == 'participants'

    name if name.to_s.match?(Umi::Fbig::BusinessDiscoveryService::HANDLE)
  end

  # Skip the Graph call entirely when everything it could tell us is already
  # known — a stored handle and an avatar already attached. That covers the
  # cohort whose only defect is the name.
  def profile_for(contact, contact_inbox)
    if contact.avatar.attached? && contact.additional_attributes['social_instagram_user_name'].present?
      return { 'username' => contact.additional_attributes['social_instagram_user_name'], 'local' => true }
    end

    api.get_object(contact_inbox.source_id) || {}
  rescue Koala::Facebook::AuthenticationError
    raise
  rescue StandardError => e
    # Error 230 and friends: the profile API is denied, but participants still
    # answers, so this is not the end of the road for the name.
    @graph_error = true
    Umi::FbigTrace.log(:profile_denied, contact: contact.id, reason: e.class.name)
    {}
  end

  def resolve_name(contact, contact_inbox, platform, profile)
    return [nil, nil] unless rename_allowed?(contact, contact_inbox)
    # The local rung carries a handle, never a display name. Once we have
    # written a name, re-reading it would rename a real name Meta gave us in an
    # earlier cycle back down to the handle — a silent one-way downgrade.
    return [nil, nil] if profile['local'] && contact.additional_attributes['umi_profile_name'].present?

    from_profile = name_from_profile(profile, platform)
    return [from_profile, profile['local'] ? 'local' : 'profile_api'] if from_profile

    handle = Umi::Fbig::ParticipantNameService.new(@channel).name_for(contact_inbox.source_id, platform: platform)
    # Participants swallows its own errors, so a nil here after the profile API
    # already errored means Meta told us nothing at all — not that this person
    # has no name.
    handle ? [handle, 'participants'] : [nil, nil]
  end

  def name_from_profile(profile, platform)
    if platform == :instagram
      profile['name'].presence || profile['username'].presence
    else
      [profile['first_name'], profile['last_name']].compact_blank.join(' ').presence
    end
  end

  def apply_avatar(contact, contact_inbox, resolution)
    return false if resolution.avatar_url.blank?

    attach_avatar(contact, contact_inbox, resolution.avatar_url)
  end

  # One transaction: a crash between the stamp and the rename would leave
  # umi_profile_name holding the new name while contacts.name still holds the
  # placeholder, and the value-equality gate would then refuse that contact
  # forever — invisible to both the name-shape census and the freshness stamps.
  # The ledger is inside too, so it can never claim a write that rolled back.
  def apply_name(contact, contact_inbox, resolution, renaming:, attached:)
    ActiveRecord::Base.transaction do
      record_ledger(contact_inbox, 'name', contact.name, resolution.name, resolution.source) if renaming

      merge_attributes(contact, name: (renaming ? resolution.name : nil), handle: resolution.handle,
                                succeeded: resolution.name.present? || attached,
                                extra: (resolution.extra || {}).merge('umi_profile_checked_at' => Time.current.iso8601))
      contact.reload
      # The SQL merge above already refused if an erasure landed since this
      # contact was selected; the rename and its ledger row must roll back with
      # it, or a statutory erasure gets undone minutes after it was honoured.
      raise ActiveRecord::Rollback if contact.additional_attributes['umi_profile_redacted']

      # Partial update: a name-only UPDATE that still fires before_save, so
      # Contacts::SyncAttributes promotes visitor -> lead from the reloaded hash.
      contact.update!(name: resolution.name) if renaming
    end
  end

  def preview(resolution, renaming)
    # The discovery stamp is bookkeeping, not a change worth reporting in a
    # dry run — counting it would mark every contact as changing.
    changing = renaming || resolution.avatar_url.present? || resolution.extra.to_h.except(DISCOVERY_STAMP).present?
    Outcome.new(status: (changing ? :would_change : :unchanged),
                name: resolution.name, avatar: resolution.avatar_url)
  end

  # Written as SQL rather than a model save because Avatar::AvatarFromUrlJob
  # rewrites this whole column from a job-start snapshot in an ensure block —
  # a read-modify-write here would race it.
  #
  # The nested handle is merged via jsonb_build_object rather than jsonb_set:
  # jsonb_set with create_if_missing only creates the FINAL key, so pathing
  # into '{social_profiles,instagram}' is a silent no-op whenever the contact
  # has no social_profiles object yet — which is every contact this feature
  # targets. Unrelated social profiles still survive the merge.
  #
  # The redaction tombstone is re-checked here in SQL, not just in Ruby: a run
  # walks up to `cap` contacts over minutes, so an erasure can land between the
  # contact being loaded and being written.
  def merge_attributes(contact, name:, handle:, succeeded:, extra: {})
    flat = extra.dup
    flat['umi_profile_last_success_at'] = Time.current.iso8601 if succeeded
    flat['umi_profile_name'] = name if name
    flat['social_instagram_user_name'] = handle if handle

    Contact.connection.exec_update(Contact.sanitize_sql_array([merge_sql(handle), *merge_binds(flat, handle, contact)]))
  end

  def merge_sql(handle)
    social = if handle
               " || jsonb_build_object('social_profiles', " \
                 "COALESCE(additional_attributes->'social_profiles', '{}'::jsonb) || jsonb_build_object('instagram', ?::text))"
             else
               ''
             end
    "UPDATE contacts SET additional_attributes = COALESCE(additional_attributes, '{}'::jsonb) || ?::jsonb#{social} " \
      "WHERE id = ? AND COALESCE(additional_attributes->>'umi_profile_redacted', 'false') != 'true'"
  end

  def merge_binds(flat, handle, contact)
    handle ? [flat.to_json, handle, contact.id] : [flat.to_json, contact.id]
  end

  # Deliberately not Avatar::AvatarFromUrlJob: its guard reads a timestamp
  # written only after the download, so concurrent workers both pass it and the
  # loser violates the Contact-avatar uniqueness index unrescued. SafeFetch is
  # still used — bypassing the job also bypasses the model-level avatar
  # validation, leaving it as the only content-type and size enforcement.
  # Gap-fill only: an existing avatar is never replaced.
  def attach_avatar(contact, contact_inbox, url)
    attached = false
    SafeFetch.fetch(url, max_bytes: MAX_AVATAR_BYTES, allowed_content_type_prefixes: [],
                         allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES) do |file|
      # Download happens outside the lock; only the attach is serialized.
      ActiveRecord::Base.transaction(requires_new: true) do
        fresh = Contact.lock.find(contact.id)
        # Re-read under the lock: an erasure may have landed since this contact
        # was selected, and redaction purges the avatar we would re-attach.
        next if fresh.avatar.attached? || fresh.additional_attributes['umi_profile_redacted']

        record_ledger(contact_inbox, 'avatar', nil, url, 'profile_api')
        fresh.avatar.attach(io: file.tempfile, filename: file.original_filename, content_type: file.content_type)
        attached = fresh.avatar.attached?
      end
    end
    # Report what actually happened: the skip paths above commit normally, so
    # returning a bare true would claim an avatar write for a contact whose
    # avatar was never touched — and stamp last_success_at for it.
    attached
  rescue ActiveRecord::RecordNotUnique
    # A concurrent writer attached first. Its avatar stands.
    Umi::FbigTrace.log(:avatar_conflict, contact: contact.id)
    false
  rescue SafeFetch::Error => e
    Umi::FbigTrace.log(:avatar_failed, contact: contact.id, reason: e.class.name)
    false
  end

  def record_ledger(contact_inbox, attribute, old_value, new_value, source)
    Umi::ProfileLedgerEntry.create!(
      run_id: @run_id, contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id,
      attribute_name: attribute, old_value: old_value, new_value: new_value,
      evidence_source: source, graph_response_digest: Digest::SHA256.hexdigest(new_value.to_s)[0, 16],
      created_at: Time.current
    )
  end

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
