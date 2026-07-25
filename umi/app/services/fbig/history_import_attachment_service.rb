# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
# rubocop:disable Rails/SkipsModelValidations
class Umi::Fbig::HistoryImportAttachmentService
  Descriptor = Data.define(:file_type, :url)
  Plan = Data.define(:descriptors, :omissions)
  StagedAttachment = Data.define(:blob, :file_type, :extension)
  StageResult = Data.define(:attachments, :omissions, :bytes_used) do
    def initialize(attachments:, omissions:, bytes_used: nil)
      bytes_used ||= attachments.sum { |attachment| attachment.blob.byte_size }
      super(attachments: attachments, omissions: omissions, bytes_used: bytes_used)
    end
  end

  class StageError < StandardError
    attr_reader :bytes_used, :budget_exhausted

    def initialize(message = nil, bytes_used: 0, budget_exhausted: false)
      @bytes_used = bytes_used
      @budget_exhausted = budget_exhausted
      super(message)
    end
  end

  class TransientError < StageError; end
  class CleanupError < StageError; end
  class UnsafeConfigurationError < StandardError; end

  class BudgetExceeded < StageError
    def initialize(bytes_used)
      super('shared download budget exhausted', bytes_used: bytes_used, budget_exhausted: true)
    end
  end

  MAX_ATTACHMENTS = 15
  FETCH_OPTIONS = {
    image: {
      allowed_content_type_prefixes: ['image/'],
      allowed_content_types: []
    },
    video: {
      allowed_content_type_prefixes: ['video/'],
      allowed_content_types: []
    },
    file: {
      allowed_content_type_prefixes: [],
      allowed_content_types: Attachment::ACCEPTABLE_FILE_TYPES + Attachment::GENERIC_FILE_CONTENT_TYPES
    }
  }.freeze

  def plan(detail)
    omissions = Hash.new(0)
    descriptors = Array(detail.dig('attachments', 'data')).filter_map do |attachment|
      descriptor = descriptor_for(attachment)
      omissions[:unsupported_shape] += 1 unless descriptor
      descriptor
    end

    omissions[:attachment_limit] += descriptors.size - MAX_ATTACHMENTS if descriptors.size > MAX_ATTACHMENTS
    Plan.new(descriptors: descriptors.first(MAX_ATTACHMENTS), omissions: omissions)
  end

  def stage(detail_or_plan, remaining_budget_bytes: nil)
    raise UnsafeConfigurationError if SafeFetch.allow_private_network?

    attachment_plan = detail_or_plan.is_a?(Plan) ? detail_or_plan : plan(detail_or_plan)
    omissions = attachment_plan.omissions.dup
    staged = []
    bytes_used = 0
    attachment_plan.descriptors.each do |descriptor|
      budget_limit = attachment_budget_limit(remaining_budget_bytes, bytes_used)
      raise BudgetExceeded, bytes_used if budget_limit&.zero?

      bytes_used += stage_one(descriptor, staged, omissions, budget_limit, bytes_used)
      raise BudgetExceeded, bytes_used if remaining_budget_bytes && bytes_used > remaining_budget_bytes
    end
    StageResult.new(attachments: staged, omissions: omissions, bytes_used: bytes_used)
  rescue UnsafeConfigurationError
    raise
  rescue StageError => e
    cleanup_after_stage_error!(staged, omissions, e)
  rescue StandardError => e
    cleanup_after_stage_error!(
      staged,
      omissions,
      TransientError.new(e.class.name, bytes_used: bytes_used.to_i)
    )
  end

  def persist!(stage_result, message_id:, account_id:, created_at:)
    stage_result.attachments.each do |staged|
      attachment_id = Attachment.insert_all!(
        [{
          message_id: message_id,
          account_id: account_id,
          file_type: Attachment.file_types.fetch(staged.file_type),
          extension: staged.extension,
          external_url: nil,
          meta: { umi_history_import: true },
          created_at: created_at,
          updated_at: created_at
        }],
        returning: %w[id]
      ).rows.dig(0, 0)

      ActiveStorage::Attachment.insert_all!([{
                                              name: 'file',
                                              record_type: 'Attachment',
                                              record_id: attachment_id,
                                              blob_id: staged.blob.id,
                                              created_at: created_at
                                            }])
    end

    stage_result.attachments.size
  end

  def cleanup_unattached!(stage_result)
    blob_ids = stage_result.attachments.map { |staged| staged.blob.id }
    attached_ids = ActiveStorage::Attachment.where(blob_id: blob_ids).distinct.pluck(:blob_id).to_set
    errors = []
    stage_result.attachments.reject { |staged| attached_ids.include?(staged.blob.id) }.each do |staged|
      blob = ActiveStorage::Blob.find_by(id: staged.blob.id)
      begin
        blob&.purge
      rescue StandardError => e
        errors << e.class.name
      end
    end
    raise CleanupError, errors.join(',') if errors.any?

    true
  rescue StandardError => e
    raise if e.is_a?(CleanupError)

    raise CleanupError, e.class.name
  end

  def cleanup_all_unattached!(stage_results)
    errors = []
    Array(stage_results).each do |stage_result|
      cleanup_unattached!(stage_result)
    rescue CleanupError => e
      errors << e.message
    end
    raise CleanupError, errors.join(',') if errors.any?

    true
  end

  private

  def cleanup_after_stage_error!(staged, omissions, error)
    cleanup_unattached!(
      StageResult.new(
        attachments: staged || [],
        omissions: omissions || {},
        bytes_used: error.bytes_used
      )
    )
    raise error
  rescue CleanupError => e
    raise CleanupError.new(
      e.message,
      bytes_used: error.bytes_used,
      budget_exhausted: error.budget_exhausted
    )
  end

  def descriptor_for(attachment)
    if attachment.dig('image_data', 'url').present?
      Descriptor.new(file_type: :image, url: attachment.dig('image_data', 'url'))
    elsif attachment.dig('video_data', 'url').present?
      Descriptor.new(file_type: :video, url: attachment.dig('video_data', 'url'))
    elsif attachment['file_url'].present?
      Descriptor.new(file_type: :file, url: attachment['file_url'])
    end
  end

  def stage_one(descriptor, staged, omissions, budget_limit, bytes_used)
    options = FETCH_OPTIONS.fetch(descriptor.file_type)
    max_bytes = [budget_limit, default_max_bytes].compact.min
    options = options.merge(max_bytes: max_bytes) if max_bytes
    downloaded_bytes = 0
    SafeFetch.fetch(descriptor.url, **options) do |result|
      downloaded_bytes = result.tempfile.size
      filename = sanitized_filename(result.filename)
      unless acceptable_generic_file?(descriptor, result.content_type, filename)
        omissions[:unsupported_content_type] += 1
        next
      end

      blob = ActiveStorage::Blob.build_after_unfurling(
        io: result.tempfile,
        filename: filename,
        content_type: result.content_type,
        identify: false
      )
      blob.save!
      staged << StagedAttachment.new(
        blob: blob,
        file_type: descriptor.file_type,
        extension: ActiveStorage::Filename.new(filename).extension.downcase.presence
      )
      result.tempfile.rewind
      blob.upload_without_unfurling(result.tempfile)
    end
    downloaded_bytes
  rescue SafeFetch::InvalidUrlError
    omissions[:invalid_url] += 1
    0
  rescue SafeFetch::UnsafeUrlError
    omissions[:unsafe_url] += 1
    0
  rescue SafeFetch::FileTooLargeError
    raise BudgetExceeded, bytes_used + budget_limit if budget_limit && budget_limit <= default_max_bytes

    omissions[:file_too_large] += 1
    max_bytes.to_i
  rescue SafeFetch::UnsupportedContentTypeError
    omissions[:unsupported_content_type] += 1
    0
  rescue SafeFetch::HttpError => e
    status = e.message.to_i
    raise TransientError.new(e.class.name, bytes_used: bytes_used) if status == 429 || status >= 500

    omissions[status.in?([404, 410]) ? :unavailable_url : :http_error] += 1
    0
  rescue SafeFetch::FetchError => e
    raise TransientError.new(
      e.class.name,
      bytes_used: bytes_used + max_bytes.to_i,
      budget_exhausted: !budget_limit.nil? && max_bytes == budget_limit
    )
  rescue StageError
    raise
  rescue StandardError => e
    raise TransientError.new(e.class.name, bytes_used: bytes_used + downloaded_bytes)
  end

  def sanitized_filename(filename)
    sanitized = ActiveStorage::Filename.new(filename.presence || 'history-attachment').sanitized
    sanitized.truncate(255, omission: '')
  end

  def attachment_budget_limit(remaining_budget_bytes, bytes_used)
    return unless remaining_budget_bytes

    [remaining_budget_bytes.to_i - bytes_used, 0].max
  end

  def default_max_bytes
    limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', SafeFetch::DEFAULT_MAX_BYTES_FALLBACK_MB).to_i
    limit_mb = SafeFetch::DEFAULT_MAX_BYTES_FALLBACK_MB if limit_mb <= 0
    limit_mb.megabytes
  end

  def acceptable_generic_file?(descriptor, content_type, filename)
    return true unless descriptor.file_type == :file && Attachment::GENERIC_FILE_CONTENT_TYPES.include?(content_type)

    Attachment::ACCEPTABLE_FILE_EXTENSIONS.include?(ActiveStorage::Filename.new(filename).extension.downcase)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
# rubocop:enable Rails/SkipsModelValidations
