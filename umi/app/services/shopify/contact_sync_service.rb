# frozen_string_literal: true

# UMI patch: upserts one page (≤250) of Shopify customers into an account's
# contacts. Used by the backfill chain (mode :bulk — Contact.import, no
# per-record callbacks/events) and the incremental poll (mode :per_record —
# Contact.create!, so contact_created events fire for the small change sets).
#
# Contacts are matched by email (downcased) then phone. There is NO unique index
# on (phone_number, account_id) — phone dedup is entirely application-level, so
# rows are deduped in-memory before insert (the most recently updated customer
# keeps a shared key) and the whole sync runs under Umi::Shopify::SyncLock.
#
# Enrichment of existing contacts is fill-blanks-only — Shopify never overwrites
# agent-entered data — with one exception: a placeholder name (the phone number,
# the email local part, or a Haikunator name) counts as blank, mirroring
# Twilio::IncomingMessageService's name-upgrade rule. A contact already linked to
# a *different* shopify_customer_id is never touched (two customers sharing a
# phone must not flap the contact's identity, and redact must never hit the
# wrong person) — counted as `conflicted`.
class Umi::Shopify::ContactSyncService
  HAIKUNATOR_NAME = /\A[a-z]+-[a-z]+-\d+\z/i

  def initialize(account:, customers:, mode: :bulk)
    @account = account
    @customers = customers
    @mode = mode
    @counters = Hash.new(0)
  end

  def perform
    rows = dedup(mapped_rows)
    existing_by_email, existing_by_phone = existing_contacts(rows)

    new_rows = rows.reject do |row|
      contact = existing_by_email[row[:email]] || existing_by_phone[row[:phone_number]]
      enrich(contact, row, existing_by_phone) if contact
      contact
    end

    create_contacts(new_rows)
    @counters
  end

  private

  def mapped_rows
    @customers.filter_map do |customer|
      result = Umi::Shopify::CustomerContactMapper.map(customer)
      @counters[:dropped_email] += 1 if result.dropped_email
      @counters[:dropped_phone] += 1 if result.dropped_phone
      @counters[:skipped_no_identity] += 1 if result.attributes.nil?
      next if result.attributes.nil?

      result.attributes.merge(updated_at_hint: result.updated_at)
    end
  end

  # Newest-first so the most recently updated customer keeps a shared email or
  # phone; the loser keeps its other key or is dropped entirely.
  def dedup(rows)
    seen = { email: Set.new, phone_number: Set.new }

    rows.sort_by { |row| row[:updated_at_hint] || Time.zone.at(0) }.reverse.filter_map do |row|
      row.delete(:updated_at_hint)
      strip_seen_keys(row, seen)
      row if row[:email] || row[:phone_number]
    end
  end

  def strip_seen_keys(row, seen)
    seen.each do |key, values|
      value = row[key]
      next if value.nil?

      if values.include?(value)
        row[key] = nil
        @counters[:deduped] += 1
      else
        values.add(value)
      end
    end
  end

  def existing_contacts(rows)
    emails = rows.filter_map { |row| row[:email] }
    phones = rows.filter_map { |row| row[:phone_number] }
    scope = @account.contacts.where('lower(email) IN (?)', emails.presence || [''])
                    .or(@account.contacts.where(phone_number: phones.presence || ['']))
    index_by_identity(scope)
  end

  def index_by_identity(contacts)
    by_email = {}
    by_phone = {}
    contacts.each do |contact|
      by_email[contact.email.downcase] = contact if contact.email.present?
      by_phone[contact.phone_number] = contact if contact.phone_number.present?
    end
    [by_email, by_phone]
  end

  def enrich(contact, row, existing_by_phone)
    # Fresh read FIRST: the identity guard must see a shopify_customer_id
    # persisted moments ago by the always-on orders-sidebar link path, and
    # whole-jsonb writes are last-write-wins against concurrent agent edits
    # (residual race accepted in the spec).
    contact.reload
    incoming_id = row[:additional_attributes]['shopify_customer_id']
    existing_id = contact.additional_attributes['shopify_customer_id']
    if existing_id.present? && existing_id.to_s != incoming_id.to_s
      @counters[:conflicted] += 1
      Rails.logger.warn("[umi-contact-sync] contact #{contact.id} already linked to shopify customer " \
                        "#{existing_id}; not overwriting with #{incoming_id}")
      return
    end

    assign_enrichment(contact, row, existing_by_phone)

    if contact.changed?
      contact.save!
      @counters[:enriched] += 1
    else
      @counters[:unchanged] += 1
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    @counters[:failed] += 1
    Rails.logger.warn("[umi-contact-sync] enrich failed for contact #{contact.id}: #{e.message}")
  end

  def assign_enrichment(contact, row, existing_by_phone)
    assign_identity(contact, row, existing_by_phone)
    contact.contact_type = 'customer'
    contact.additional_attributes = merged_additional_attributes(contact, row)
    contact.location = contact.additional_attributes['city'] if contact.location.blank?
    contact.country_code = contact.additional_attributes['country'] if contact.country_code.blank?
  end

  def assign_identity(contact, row, existing_by_phone)
    contact.name = row[:name] if placeholder_name?(contact) && row[:name].present?
    contact.email = row[:email] if contact.email.blank? && row[:email].present?
    contact.phone_number = row[:phone_number] if fillable_phone?(contact, row, existing_by_phone)
  end

  # Split-identity guard: when the customer's email matched contact A but its
  # phone already belongs to contact B, filling A would duplicate the phone
  # across contacts (no unique index stops it) and make caller-ID resolution
  # nondeterministic — the exact thing this sync exists to fix.
  def fillable_phone?(contact, row, existing_by_phone)
    return false if contact.phone_number.present? || row[:phone_number].blank?

    owner = existing_by_phone[row[:phone_number]]
    owner.nil? || owner.id == contact.id
  end

  # shopify_* keys are sync-owned and kept current — including removals (a tag
  # or consent record cleared in Shopify must clear here, so a nil deletes the
  # key). city/country are shared with other writers and only ever filled.
  def merged_additional_attributes(contact, row)
    merged = contact.additional_attributes.dup
    Umi::Shopify::CustomerContactMapper::SHOPIFY_KEYS.each do |key|
      value = row[:additional_attributes][key]
      value.nil? ? merged.delete(key) : merged[key] = value
    end
    %w[city country].each do |key|
      merged[key] = row[:additional_attributes][key] if merged[key].blank? && row[:additional_attributes][key].present?
    end
    merged
  end

  def placeholder_name?(contact)
    name = contact.name.to_s.strip
    return true if name.blank?
    return true if name == contact.phone_number
    return true if contact.email.present? && [contact.email, contact.email.split('@').first].include?(name)

    return true if name == contact.additional_attributes['umi_profile_name']

    name.match?(HAIKUNATOR_NAME)
  end

  def create_contacts(rows)
    @mode == :bulk ? bulk_create(rows) : per_record_create(rows)
  end

  # Fresh contacts don't store the mapper's "cleared in Shopify" nils.
  def compact_attributes(row)
    row.merge(additional_attributes: row[:additional_attributes].compact)
  end

  def bulk_create(rows)
    contacts = rows.map { |row| @account.contacts.new(compact_attributes(row)) }
    return if contacts.empty?

    result = Contact.import(contacts, validate: true, on_duplicate_key_ignore: true,
                                      track_validation_failures: true, batch_size: 1000)
    @counters[:created] += result.ids.size
    @counters[:failed] += result.failed_instances.size
  end

  def per_record_create(rows)
    rows.each do |row|
      @account.contacts.create!(compact_attributes(row))
      @counters[:created] += 1
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @counters[:failed] += 1
      Rails.logger.warn('[umi-contact-sync] create failed for shopify customer ' \
                        "#{row.dig(:additional_attributes, 'shopify_customer_id')}: #{e.message}")
    end
  end
end
