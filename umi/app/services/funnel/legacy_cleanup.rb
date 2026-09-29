# frozen_string_literal: true

require 'fileutils'

# rubocop:disable Metrics/ClassLength, Rails/SkipsModelValidations

# A fixed, account-scoped removal with private, expiring before-images.
class Umi::Funnel::LegacyCleanup
  MIGRATION = 'stage-one-20260930'
  NOTE_MARKER = 'umi_legacy_shopify_context'
  LABELS = %w[value-first-time value-returning value-vip value-influencer value-wholesale value-high-value lead-new lead-lost
              lead-unqualified intent-interested intent-waiting-reply intent-waiting-payment source-organic].freeze
  KEYS = %w[shopify_summary shopify_orders shopify_lifetime_spent shopify_last_order shopify_last_status shopify_order_link
            shopify_customer_since shopify_tags shopify_address shopify_phone].freeze

  def self.root
    Rails.root.join('storage/umi-stage-one-cleanup/account-1')
  end

  def self.purge_contact!(contact)
    return unless contact.account_id == 1

    FileUtils.rm_f(root.join("contact-#{contact.id}.json"))
    root.glob(".contact-#{contact.id}-*.tmp").each { |path| FileUtils.rm_f(path) }
    Message.where(account_id: contact.account_id, private: true).find_each do |message|
      message.destroy! if message.content_attributes[NOTE_MARKER] == note_marker(contact)
    end
  end

  def self.note_marker(contact)
    { 'migration' => MIGRATION, 'account_id' => contact.account_id, 'contact_id' => contact.id }
  end

  def initialize(root: self.class.root, review_sentinel_confirmed: false)
    @root = Pathname(root)
    @keys = KEYS + (review_sentinel_confirmed ? ['review_sentinel'] : [])
  end

  def inventory # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    FileUtils.mkdir_p(@root, mode: 0o700)
    File.chmod(0o700, @root)
    prune
    present = manifest?
    @keys = read('manifest').fetch('keys') if present
    return summary if present && read('manifest')['inventory_complete']

    account = Account.find(1)
    check_writers!(account)
    unless present
      atomic('manifest', { migration: MIGRATION, created_at: Time.current.iso8601, status: 'open', keys: @keys,
                           labels: account.labels.where(title: LABELS).map(&:attributes),
                           definitions: account.custom_attribute_definitions.where(attribute_key: @keys).map(&:attributes),
                           rule: account.automation_rules.find_by(id: 1)&.attributes })
    end
    account.contacts.find_each do |contact|
      contact.with_lock do
        next if redacted?(contact) || @root.join("contact-#{contact.id}.json").exist?

        records = locked_records(contact)
        rows = records.map { |record| snapshot(record) }
        next unless rows.any? { |row| row['values'].present? || row['taggings'].present? }

        atomic("contact-#{contact.id}", { created_at: Time.current.iso8601, binding: binding(contact), rows: rows, status: 'preview' })
      end
    end
    atomic('manifest', read('manifest').merge('inventory_complete' => true))
    summary
  end

  def apply
    mutate(:apply)
  end

  def restore
    mutate(:restore)
  end

  def prune # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return unless @root.exist?

    manifest = read('manifest')
    expired = manifest && Time.iso8601(manifest.fetch('created_at')) < 30.days.ago
    (@root.glob('contact-*.json') + @root.glob('.contact-*.tmp')).each do |path|
      contact = Contact.find_by(id: path.basename.to_s[/\d+/].to_i, account_id: 1)
      if contact
        contact.with_lock { FileUtils.rm_f(path) if expired || redacted?(contact) || path.extname == '.tmp' }
      else
        FileUtils.rm_f(path)
      end
    end
    return unless expired || !Account.exists?(1)

    atomic('manifest', { migration: MIGRATION, created_at: manifest&.fetch('created_at', nil) || Time.current.iso8601, status: 'closed' })
  end

  private

  def manifest?
    manifest = read('manifest')
    raise ArgumentError, 'Cleanup operation is closed' if manifest && manifest['status'] == 'closed'

    manifest.present?
  end

  def mutate(operation) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    prune
    raise ArgumentError, 'Inventory required' unless manifest?

    manifest = read('manifest')
    raise ArgumentError, 'Inventory incomplete' unless manifest['inventory_complete']

    @keys = manifest.fetch('keys')
    account = Account.find(1)
    check_writers!(account)
    check_references!(account)
    result = { applied: 0, held: 0, purged: 0 }
    @root.glob('contact-*.json').sort.each do |path|
      contact = account.contacts.find_by(id: path.basename.to_s[/\d+/].to_i)
      unless contact
        FileUtils.rm_f(path)
        result[:purged] += 1
        next
      end
      state = process_contact(contact, path, operation)
      result[state] += 1
    end
    catalog(account, operation) if result[:held].zero?
    ActsAsTaggableOn::Tag.where(name: LABELS).find_each do |tag|
      tag.update_columns(taggings_count: ActsAsTaggableOn::Tagging.where(tag_id: tag.id).count)
    end
    account.update_cache_key('label')
    Conversations::UnreadCounts::FilteredCountInvalidator.new(account).conversation_changed!
    result
  end

  def check_writers!(account) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    rule = account.automation_rules.find_by(id: 1)
    if rule&.actions&.none? { |action| action['action_name'] == 'add_label' && Array(action['action_params']).include?('lead-new') }
      raise ArgumentError, 'Rule 1 is not the retired lead-new writer'
    end
    raise ArgumentError, 'Stop legacy and customer writers first' if rule&.active? ||
                                                                     Umi::Funnel::ConversationClassifier.mode == 'auto' ||
                                                                     Umi::Funnel::Configuration.customer_context_enabled?(1)
  end

  def check_references!(account)
    filters = account.custom_filters.any? { |filter| references?(filter.query) }
    widgets = account.inboxes.where(channel_type: 'Channel::WebWidget').any? { |inbox| references?(inbox.channel.pre_chat_form_options) }
    conflicts = account.custom_attribute_definitions.exists?(attribute_key: @keys, attribute_model: :company_attribute)
    raise ArgumentError, 'Resolve retired attribute references or conflicting definitions first' if filters || widgets || conflicts
  end

  def references?(value)
    case value
    when Hash then value.any? { |key, item| @keys.include?(key.to_s) || references?(item) }
    when Array then value.any? { |item| references?(item) }
    when String then @keys.include?(value)
    else false
    end
  end

  def process_contact(contact, path, operation) # rubocop:disable Metrics/MethodLength
    outcome = contact.with_lock do
      if redacted?(contact)
        FileUtils.rm_f(path)
        next :purged
      end
      mutate_contact(contact, JSON.parse(path.read), operation)
    end
    return outcome unless outcome == :applied

    # Reacquire the same erasure boundary before recording the committed outcome.
    contact.with_lock do
      if redacted?(contact) || !path.exist?
        FileUtils.rm_f(path)
        next :purged
      end
      saved = JSON.parse(path.read)
      saved['status'] = operation == :apply ? 'applied' : 'restored'
      atomic(path.basename('.json').to_s, saved)
      :applied
    end
  rescue ActiveRecord::RecordNotFound
    FileUtils.rm_f(path)
    :purged
  end

  def mutate_contact(contact, saved, operation) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
    return :held if operation == :apply && saved['status'] == 'restored'
    return :held unless binding(contact) == saved.fetch('binding')

    actual = locked_records(contact).index_by { |record| [record.class.name, record.id] }
    rows = saved.fetch('rows')
    return :held unless rows.all? { |row| actual.key?([row['type'], row['id']]) }

    pairs = rows.map { |row| [actual.fetch([row['type'], row['id']]), row] }
    if operation == :restore
      return :held unless %w[applying applied restoring restored].include?(saved['status'])

      restored = pairs.all? { |record, row| snapshot(record) == row }
      return restored ? :applied : :held if saved['status'] == 'restored'
      return :applied if saved['status'] == 'restoring' && restored
    end

    if operation == :apply
      return :applied if %w[applying applied].include?(saved['status']) && pairs.all? { |record, row| output?(record, row) }
      return :held unless pairs.all? { |record, row| snapshot(record) == row }

      atomic("contact-#{contact.id}", saved.merge('status' => 'applying'))
      preserve_unverified_context!(contact, saved) if contact.id == 1388
      pairs.each { |pair| remove_owned!(pair.first) }
    else
      return :held unless rows.flat_map { |row| row['taggings'] }.all? { |attrs| ActsAsTaggableOn::Tag.exists?(attrs.fetch('tag_id')) }
      return :held unless pairs.all? { |record, row| output?(record, row) }

      atomic("contact-#{contact.id}", saved.merge('status' => 'restoring'))
      pairs.each { |record, row| restore_owned!(record, row) }
    end
    :applied
  end

  def locked_records(contact)
    [contact] + contact.conversations.reorder(:id).lock.to_a
  end

  def binding(contact)
    contact.additional_attributes.slice('shopify_customer_id', 'umi_klaviyo_profile_id', 'umi_klaviyo_binding')
  end

  def redacted?(contact)
    contact.additional_attributes['umi_profile_redacted'].present?
  end

  def taggings(record)
    ActsAsTaggableOn::Tagging.where(taggable_type: record.class.name, taggable_id: record.id, context: 'labels')
                             .where(tag_id: ActsAsTaggableOn::Tag.where(name: LABELS).select(:id))
  end

  def snapshot(record)
    JSON.parse(JSON.generate({ 'type' => record.class.name, 'id' => record.id, 'values' => record.custom_attributes.slice(*@keys),
                               'taggings' => taggings(record).order(:id).map { |tagging| tagging.attributes.except('id') } }))
  end

  def output?(record, _row)
    record.custom_attributes.slice(*@keys).empty? && !taggings(record).exists?
  end

  def remove_owned!(record)
    record.update_columns(custom_attributes: record.custom_attributes.except(*@keys))
    taggings(record).delete_all
    update_label_cache(record)
  end

  def restore_owned!(record, row)
    record.update_columns(custom_attributes: record.custom_attributes.merge(row.fetch('values')))
    row.fetch('taggings').each { |attrs| ActsAsTaggableOn::Tagging.insert_all!([attrs]) }
    update_label_cache(record)
  end

  def update_label_cache(record)
    return unless record.is_a?(Conversation)

    names = ActsAsTaggableOn::Tag.joins(:taggings)
                                 .where(taggings: { taggable_type: 'Conversation', taggable_id: record.id,
                                                    context: 'labels' }).order(:name).pluck(:name)
    record.update_columns(cached_label_list: names.join(', '))
  end

  def preserve_unverified_context!(contact, saved)
    conversation = contact.conversations.reorder(:id).first
    raise ArgumentError, 'Unverified context requires an existing conversation' unless conversation
    return if conversation.messages.where(private: true).any? { |message| message.content_attributes[NOTE_MARKER] == self.class.note_marker(contact) }

    values = saved.fetch('rows').pluck('values').to_json
    conversation.messages.create!(account_id: 1, inbox_id: conversation.inbox_id, message_type: :outgoing, private: true, content_type: :text,
                                  content: "Unverified legacy Shopify context; not a confirmed customer/order link.\n#{values}",
                                  content_attributes: { NOTE_MARKER => self.class.note_marker(contact) })
  end

  def catalog(account, operation)
    account.with_lock do
      manifest = read('manifest')
      operation == :apply ? remove_catalog(account, manifest) : restore_catalog(account, manifest)
    end
    # The receipt follows the database commit. A lost receipt can be recovered
    # only from an unambiguous authorized input or committed output.
    account.with_lock do
      manifest = read('manifest')
      state = manifest['catalog']
      expected = operation == :apply ? 'applying' : 'restoring'
      next unless state && state['status'] == expected

      state['status'] = operation == :apply ? 'applied' : 'restored'
      atomic('manifest', manifest)
    end
  end

  def catalog_snapshot(account)
    JSON.parse(JSON.generate({
                               'labels' => account.labels.where(title: LABELS).reorder(:id).lock.map(&:attributes),
                               'definitions' => account.custom_attribute_definitions.where(attribute_key: @keys).order(:id).lock.map(&:attributes),
                               'rule' => account.automation_rules.lock.find_by(id: 1)&.attributes
                             }))
  end

  def remove_catalog(account, manifest) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    verify_remaining!(account)
    current = catalog_snapshot(account)
    authorized = manifest['catalog']
    if authorized
      raise ArgumentError, 'Catalog already restored' unless %w[applying applied].include?(authorized['status'])
      return if current['labels'].empty? && current['definitions'].empty? && current['rule'].nil?
      raise ArgumentError, 'Catalog changed after cleanup' if authorized['status'] == 'applied'
    end
    expected = authorized || manifest
    %w[labels definitions].each do |key|
      before = expected.fetch(key).sort_by { |attrs| attrs.fetch('id') }
      raise ArgumentError, "Retired #{key} changed since inventory" unless current.fetch(key) == before
    end
    raise ArgumentError, 'Retired rule changed since inventory' unless current['rule'] == expected['rule']

    atomic('manifest', manifest.merge('catalog' => current.merge('status' => 'applying')))
    account.labels.where(id: current.fetch('labels').pluck('id')).delete_all
    account.custom_attribute_definitions.where(id: current.fetch('definitions').pluck('id')).delete_all
    account.automation_rules.where(id: 1, active: false).delete_all if current['rule']
  end

  def restore_catalog(account, manifest) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    authorized = manifest['catalog']
    return unless authorized && %w[applying applied restoring].include?(authorized['status'])

    current = catalog_snapshot(account)
    if authorized['status'] == 'restoring'
      restored = %w[labels definitions].all? do |key|
        current.fetch(key) == authorized.fetch(key).sort_by { |attrs| attrs.fetch('id') }
      end
      raise ArgumentError, 'Catalog restore outcome is ambiguous; inspect the catalog before continuing' unless restored

      return
    end

    atomic('manifest', manifest.merge('catalog' => authorized.merge('status' => 'restoring')))
    authorized.fetch('labels').each do |attrs|
      Label.insert_all!([attrs]) unless account.labels.exists?(title: attrs.fetch('title'))
    end
    authorized.fetch('definitions').each do |attrs|
      next if account.custom_attribute_definitions.exists?(attribute_key: attrs.fetch('attribute_key'),
                                                           attribute_model: attrs.fetch('attribute_model'))

      CustomAttributeDefinition.insert_all!([attrs])
    end
    # Restoring data never re-enables the retired writer.
  end

  def verify_remaining!(account)
    [account.contacts, account.conversations].each do |scope|
      scope.find_each do |record|
        raise ArgumentError, 'Unprocessed legacy data remains; catalog retained' unless output?(record, nil)
      end
    end
  end

  def summary
    account = Account.find(1)
    expected = Umi::Funnel::Configuration::PROTECTED_LABELS + Umi::Funnel::ClassificationClient::TOPICS + ['spam']
    { unexpected_labels: account.labels.pluck(:title) - expected - LABELS,
      contacts: @root.glob('contact-*.json').size, labels: account.labels.where(title: LABELS).count,
      definitions: account.custom_attribute_definitions.where(attribute_key: @keys).count }
  end

  def read(name)
    path = @root.join("#{name}.json")
    JSON.parse(path.read) if path.exist?
  end

  def atomic(name, data)
    path = @root.join("#{name}.json")
    temp = @root.join(".#{name}-#{Process.pid}-#{SecureRandom.hex(4)}.tmp")
    File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.generate(data))
      file.flush
      file.fsync
    end
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if temp
  end
end

# rubocop:enable Metrics/ClassLength, Rails/SkipsModelValidations
