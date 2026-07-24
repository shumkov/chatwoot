# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
# rubocop:disable Rails/SkipsModelValidations
class Umi::Fbig::HistoryImportAttachmentService
  Descriptor = Data.define(:file_type, :url)
  Plan = Data.define(:descriptors, :omissions)
  StagedAttachment = Data.define(:blob, :file_type, :extension)
  StageResult = Data.define(:attachments, :omissions)

  class TransientError < StandardError; end
  class CleanupError < StandardError; end
  class UnsafeConfigurationError < StandardError; end

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

  def stage(detail_or_plan)
    raise UnsafeConfigurationError if SafeFetch.allow_private_network?

    attachment_plan = detail_or_plan.is_a?(Plan) ? detail_or_plan : plan(detail_or_plan)
    omissions = attachment_plan.omissions.dup
    staged = []
    attachment_plan.descriptors.each { |descriptor| stage_one(descriptor, staged, omissions) }
    StageResult.new(attachments: staged, omissions: omissions)
  rescue UnsafeConfigurationError, CleanupError
    raise
  rescue StandardError => e
    cleanup_unattached!(StageResult.new(attachments: staged || [], omissions: omissions || {}))
    raise e if e.is_a?(TransientError)

    raise TransientError, e.class.name
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

  def descriptor_for(attachment)
    if attachment.dig('image_data', 'url').present?
      Descriptor.new(file_type: :image, url: attachment.dig('image_data', 'url'))
    elsif attachment.dig('video_data', 'url').present?
      Descriptor.new(file_type: :video, url: attachment.dig('video_data', 'url'))
    elsif attachment['file_url'].present?
      Descriptor.new(file_type: :file, url: attachment['file_url'])
    end
  end

  def stage_one(descriptor, staged, omissions)
    SafeFetch.fetch(descriptor.url, **FETCH_OPTIONS.fetch(descriptor.file_type)) do |result|
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
  rescue SafeFetch::InvalidUrlError
    omissions[:invalid_url] += 1
  rescue SafeFetch::UnsafeUrlError
    omissions[:unsafe_url] += 1
  rescue SafeFetch::FileTooLargeError
    omissions[:file_too_large] += 1
  rescue SafeFetch::UnsupportedContentTypeError
    omissions[:unsupported_content_type] += 1
  rescue SafeFetch::HttpError => e
    status = e.message.to_i
    raise TransientError, e.class.name if status == 429 || status >= 500

    omissions[status.in?([404, 410]) ? :unavailable_url : :http_error] += 1
  rescue SafeFetch::FetchError => e
    raise TransientError, e.class.name
  end

  def sanitized_filename(filename)
    sanitized = ActiveStorage::Filename.new(filename.presence || 'history-attachment').sanitized
    sanitized.truncate(255, omission: '')
  end

  def acceptable_generic_file?(descriptor, content_type, filename)
    return true unless descriptor.file_type == :file && Attachment::GENERIC_FILE_CONTENT_TYPES.include?(content_type)

    Attachment::ACCEPTABLE_FILE_EXTENSIONS.include?(ActiveStorage::Filename.new(filename).extension.downcase)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
# rubocop:enable Rails/SkipsModelValidations
