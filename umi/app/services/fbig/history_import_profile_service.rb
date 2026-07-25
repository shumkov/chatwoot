# frozen_string_literal: true

require 'active_storage/service/mirror_service'

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
# rubocop:disable Rails/SkipsModelValidations
class Umi::Fbig::HistoryImportProfileService
  AvatarCandidate = Data.define(:url)
  Plan = Data.define(
    :platform,
    :source_id,
    :name_candidate,
    :instagram_username,
    :instagram_optional_attributes,
    :contact_attributes,
    :avatar_candidate
  )
  ApplyResult = Data.define(:status, :changed, :contact_attributes)
  AvatarResult = Data.define(:status, :bytes_used, :mirror_jobs, :incomplete, :degraded, :cleanup_failed)
  StagedAvatar = Data.define(:blob, :bytes_used, :mirror_jobs)

  class UnsafeConfigurationError < StandardError; end
  class LeaseLost < StandardError; end

  MAX_AVATAR_BYTES = 15.megabytes
  RETRY_DELAYS = [0.25, 1].freeze
  INSTAGRAM_OPTIONAL_FIELDS = {
    'follower_count' => 'social_instagram_follower_count',
    'is_user_follow_business' => 'social_instagram_is_user_follow_business',
    'is_business_follow_user' => 'social_instagram_is_business_follow_user',
    'is_verified_user' => 'social_instagram_is_verified_user'
  }.freeze

  def initialize(sleeper: ->(delay) { Kernel.sleep(delay) }, intent_store: nil, after_avatar_blob_save: nil,
                 after_avatar_upload: nil, renewer: nil)
    @sleeper = sleeper
    @intent_store = intent_store
    @after_avatar_blob_save = after_avatar_blob_save
    @after_avatar_upload = after_avatar_upload
    @renewer = renewer
  end

  def plan(platform:, source_id:, profile:, participant_name: nil, observed_sender_username: nil, contact: nil)
    platform = normalize_platform(platform)
    profile = profile.to_h.stringify_keys
    name_candidate = name_candidate_for(platform, profile, participant_name)
    instagram_username = username_candidate_for(platform, profile, observed_sender_username)
    instagram_optional_attributes = optional_instagram_attributes(platform, profile)
    contact_attributes = projected_contact_attributes(
      contact: contact,
      platform: platform,
      source_id: source_id.to_s,
      name_candidate: name_candidate,
      instagram_username: instagram_username,
      instagram_optional_attributes: instagram_optional_attributes
    )
    avatar_url = normalized_value(profile['profile_pic'])
    avatar_candidate = AvatarCandidate.new(url: avatar_url) if avatar_url && !avatar_attached?(contact)

    Plan.new(
      platform: platform,
      source_id: source_id.to_s,
      name_candidate: name_candidate,
      instagram_username: instagram_username,
      instagram_optional_attributes: instagram_optional_attributes,
      contact_attributes: contact_attributes,
      avatar_candidate: avatar_candidate
    )
  end

  def apply!(contact:, plan:)
    result = nil
    contact.with_lock do
      projected = projected_contact_attributes(
        contact: contact,
        platform: plan.platform,
        source_id: plan.source_id,
        name_candidate: plan.name_candidate,
        instagram_username: plan.instagram_username,
        instagram_optional_attributes: plan.instagram_optional_attributes
      )
      updates = scalar_updates(contact, projected)
      contact.update_columns(updates) if updates.any?
      result = ApplyResult.new(
        status: updates.any? ? :updated : :unchanged,
        changed: updates.any?,
        contact_attributes: projected
      )
    end
    result
  end

  def validate_apply_configuration!
    raise UnsafeConfigurationError, 'private-network fetching is enabled' if SafeFetch.allow_private_network?

    true
  end

  def attach_avatar(contact:, url:, remaining_budget_bytes:, avatar_intent: nil, contact_context: nil)
    validate_apply_configuration!
    checkpoint!
    already_present = with_current_contact(contact, contact_context) { |current| avatar_attached?(current) }
    return avatar_result(:already_present) if already_present
    return avatar_result(:invalid_url, degraded: true) if normalized_value(url).nil?

    remaining_bytes = remaining_budget_bytes.to_i
    return avatar_result(:budget_exhausted, incomplete: true) if remaining_bytes <= 0

    staged = fetch_and_stage_avatar(url, remaining_bytes, contact, avatar_intent)
    return staged if staged.is_a?(AvatarResult)

    associate_avatar(contact, staged, contact_context)
  end

  private

  attr_reader :sleeper

  def normalize_platform(platform)
    value = platform.to_sym
    return value if value.in?(%i[instagram messenger])

    raise ArgumentError, 'unsupported platform'
  end

  def name_candidate_for(platform, profile, participant_name)
    profile_name = if platform == :instagram
                     normalized_value(profile['name'])
                   else
                     [
                       normalized_value(profile['first_name']),
                       normalized_value(profile['last_name'])
                     ].compact.join(' ').presence
                   end

    profile_name || normalized_value(participant_name)
  end

  def username_candidate_for(platform, profile, observed_sender_username)
    return unless platform == :instagram

    normalized_value(profile['username']) || normalized_value(observed_sender_username)
  end

  def optional_instagram_attributes(platform, profile)
    return {} unless platform == :instagram

    INSTAGRAM_OPTIONAL_FIELDS.each_with_object({}) do |(profile_key, contact_key), attributes|
      value = profile[profile_key]
      attributes[contact_key] = value if profile.key?(profile_key) && !value.nil?
    end
  end

  def projected_contact_attributes(contact:, platform:, source_id:, name_candidate:, instagram_username:, instagram_optional_attributes:)
    existing_name = contact&.name.to_s
    existing_attributes = contact&.additional_attributes
    projected_name = projected_name(
      existing_name: existing_name,
      new_contact: contact.nil?,
      platform: platform,
      source_id: source_id,
      candidate: name_candidate
    )
    projected_attributes = projected_additional_attributes(
      existing_attributes,
      platform: platform,
      username: instagram_username,
      optional_attributes: instagram_optional_attributes
    )

    { name: projected_name, additional_attributes: projected_attributes }
  end

  def projected_name(existing_name:, new_contact:, platform:, source_id:, candidate:)
    return candidate.to_s if new_contact
    return existing_name unless platform == :instagram
    return existing_name unless existing_name == "Instagram user #{source_id.last(4)}"
    return existing_name if candidate.blank?

    candidate
  end

  def projected_additional_attributes(existing_attributes, platform:, username:, optional_attributes:)
    attributes = existing_attributes.is_a?(Hash) ? existing_attributes.deep_dup : {}
    return attributes unless platform == :instagram

    fill_instagram_username(attributes, username)
    optional_attributes.each do |key, value|
      attributes[key] = value unless attributes.key?(key)
    end
    attributes
  end

  def fill_instagram_username(attributes, username)
    return if username.blank?

    social_profiles = attributes['social_profiles']
    if social_profiles.nil?
      social_profiles = {}
      attributes['social_profiles'] = social_profiles
    end
    social_profiles['instagram'] = username if social_profiles.is_a?(Hash) && social_profiles['instagram'].blank?
    attributes['social_instagram_user_name'] = username if attributes['social_instagram_user_name'].blank?
  end

  def scalar_updates(contact, projected)
    {}.tap do |updates|
      updates[:name] = projected[:name] if contact.name != projected[:name]
      updates[:additional_attributes] = projected[:additional_attributes] if contact.additional_attributes != projected[:additional_attributes]
    end
  end

  def avatar_attached?(contact)
    return false unless contact&.persisted?

    ActiveStorage::Attachment.exists?(
      name: 'avatar',
      record_type: 'Contact',
      record_id: contact.id
    )
  end

  def fetch_and_stage_avatar(url, remaining_bytes, contact, avatar_intent)
    attempts = 0
    bytes_used = 0
    begin
      attempts += 1
      checkpoint!
      max_bytes = [MAX_AVATAR_BYTES, remaining_bytes - bytes_used].min
      result = SafeFetch.fetch(
        url,
        max_bytes: max_bytes,
        allowed_content_type_prefixes: [],
        allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
      ) do |result|
        stage_avatar(result, contact, avatar_intent)
      end
      checkpoint!
      with_accumulated_bytes(result, bytes_used)
    rescue SafeFetch::InvalidUrlError
      avatar_result(:invalid_url, bytes_used: bytes_used, degraded: true)
    rescue SafeFetch::UnsafeUrlError
      avatar_result(:unsafe_url, bytes_used: bytes_used, degraded: true)
    rescue SafeFetch::UnsupportedContentTypeError
      avatar_result(:unsupported_content_type, bytes_used: bytes_used, degraded: true)
    rescue SafeFetch::FileTooLargeError
      file_too_large_result(max_bytes, remaining_bytes, bytes_used)
    rescue SafeFetch::HttpError => e
      status = e.message.to_i
      if status == 429 || status >= 500
        return avatar_result(:retry_exhausted, bytes_used: bytes_used, incomplete: true) if attempts > RETRY_DELAYS.size

        checkpoint!
        sleeper.call(RETRY_DELAYS.fetch(attempts - 1))
        checkpoint!
        retry
      end

      avatar_result(:unavailable_url, bytes_used: bytes_used, degraded: true)
    rescue SafeFetch::FetchError
      bytes_used += max_bytes
      return avatar_result(:budget_exhausted, bytes_used: bytes_used, incomplete: true) if bytes_used >= remaining_bytes
      return avatar_result(:retry_exhausted, bytes_used: bytes_used, incomplete: true) if attempts > RETRY_DELAYS.size

      checkpoint!
      sleeper.call(RETRY_DELAYS.fetch(attempts - 1))
      checkpoint!
      retry
    end
  end

  def file_too_large_result(max_bytes, remaining_bytes, bytes_used)
    bytes_used += max_bytes
    return avatar_result(:budget_exhausted, bytes_used: bytes_used, incomplete: true) if bytes_used >= remaining_bytes

    avatar_result(:file_too_large, bytes_used: bytes_used, degraded: true)
  end

  def with_accumulated_bytes(result, bytes_used)
    return result if bytes_used.zero?

    result.with(bytes_used: result.bytes_used + bytes_used)
  end

  def stage_avatar(result, _contact, avatar_intent)
    bytes_used = result.tempfile.size
    checkpoint!
    if @intent_store
      raise ArgumentError, 'avatar intent context is required' unless avatar_intent

      intent = @intent_store.create!(
        source_id: avatar_intent.fetch(:source_id),
        contact_inbox_id: avatar_intent.fetch(:contact_inbox_id)
      )
      blob_key = intent.blob_key
    else
      blob_key = SecureRandom.hex(24)
    end
    blob = ActiveStorage::Blob.build_after_unfurling(
      io: result.tempfile,
      filename: sanitized_filename(result.filename),
      key: blob_key,
      content_type: result.content_type,
      identify: false
    )
    checkpoint!
    blob.save!
    @after_avatar_blob_save&.call
    result.tempfile.rewind
    checkpoint!
    blob.upload_without_unfurling(result.tempfile)
    @after_avatar_upload&.call
    checkpoint!
    mirror_jobs = blob.service.is_a?(ActiveStorage::Service::MirrorService) ? 1 : 0
    StagedAvatar.new(blob: blob, bytes_used: bytes_used, mirror_jobs: mirror_jobs)
  rescue LeaseLost
    raise
  rescue StandardError
    cleanup_result(blob, status: :storage_error, bytes_used: bytes_used.to_i, incomplete: true)
  end

  def associate_avatar(contact, staged, contact_context)
    checkpoint!
    raced = with_current_contact(contact, contact_context) do |current|
      checkpoint!
      if avatar_attached?(current)
        true
      else
        ActiveStorage::Attachment.insert_all!([{
                                                name: 'avatar',
                                                record_type: 'Contact',
                                                record_id: current.id,
                                                blob_id: staged.blob.id,
                                                created_at: Time.current
                                              }])
        checkpoint!
        false
      end
    end
    return cleanup_result(staged.blob, status: :concurrent_avatar_preserved, staged: staged) if raced

    avatar_result(:attached, bytes_used: staged.bytes_used, mirror_jobs: staged.mirror_jobs)
  rescue ActiveRecord::RecordNotUnique
    cleanup_result(staged.blob, status: :concurrent_avatar_preserved, staged: staged)
  rescue StandardError
    cleanup_result(staged.blob, status: :association_error, staged: staged, incomplete: true)
  end

  def with_current_contact(contact, contact_context, &)
    return contact_context.call(&) if contact_context

    contact.with_lock { yield contact }
  end

  def cleanup_result(blob, status:, staged: nil, bytes_used: nil, incomplete: false)
    blob&.purge
    avatar_result(
      status,
      bytes_used: bytes_used || staged&.bytes_used.to_i,
      mirror_jobs: staged&.mirror_jobs.to_i,
      incomplete: incomplete
    )
  rescue StandardError
    avatar_result(
      :cleanup_failed,
      bytes_used: bytes_used || staged&.bytes_used.to_i,
      mirror_jobs: staged&.mirror_jobs.to_i,
      incomplete: true,
      cleanup_failed: true
    )
  end

  def avatar_result(status, bytes_used: 0, mirror_jobs: 0, incomplete: false, degraded: false, cleanup_failed: false)
    AvatarResult.new(
      status: status,
      bytes_used: bytes_used,
      mirror_jobs: mirror_jobs,
      incomplete: incomplete,
      degraded: degraded,
      cleanup_failed: cleanup_failed
    )
  end

  def sanitized_filename(filename)
    ActiveStorage::Filename.new(filename.presence || 'profile-avatar').sanitized.truncate(255, omission: '')
  end

  def normalized_value(value)
    value.to_s.strip.presence
  end

  def checkpoint!
    return unless @renewer
    raise LeaseLost unless @renewer.call
  rescue LeaseLost
    raise
  rescue StandardError
    raise LeaseLost
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
# rubocop:enable Rails/SkipsModelValidations
