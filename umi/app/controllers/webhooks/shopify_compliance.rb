# frozen_string_literal: true

# UMI patch: handles the Shopify privacy-compliance webhook topics that core
# ignores. Prepended onto Webhooks::ShopifyController (HMAC verification runs in
# the parent's before_action either way); unhandled topics fall through to super.
#
# Responses are always 200: Shopify treats non-2xx as retryable and repeated
# compliance-webhook failures can flag the app — and a partial redaction retried
# blind is worse than a logged failure. A 200 also means Shopify never
# redelivers, so any failure here is the LAST chance to notice: errors go to the
# exception tracker, never just a log line.
#
# Guards on the destructive path:
# - replayed deliveries are dropped (X-Shopify-Webhook-Id remembered in Redis) —
#   the HMAC only proves origin, not freshness, and a captured redact delivery
#   must not be able to destroy a future contact that reuses the same email;
# - when the hook is already gone (Shopify can deliver after uninstall), the
#   single-account fallback only fires for the shop named in
#   UMI_SHOPIFY_SHOP_DOMAIN — all webhooks for the app share one signing secret,
#   so without this pin any shop that installed the app could redact contacts
#   in the one account.
#
# Redact policy (spec §3f): match by shopify_customer_id, then exact email. A
# phone-only match is never destroyed — shared phones are common and destroying
# would erase a different person's contact and conversations — its shopify
# attributes are stripped and the tracker pages a human. Matched contacts with
# conversations are anonymized (the conversation record is a business/audit
# record); without conversations they are destroyed outright.
# rubocop:disable Metrics/ModuleLength
# Length is inherent: Shopify mandates three separate webhook topics
# (customers/redact, shop/redact, customers/data_request) and each needs its own
# verification, replay guard and handler. Splitting them would scatter one
# statutory contract across files.
module Umi::Webhooks::ShopifyCompliance
  REPLAY_KEY_PREFIX = 'UMI_SHOPIFY_WEBHOOK_ID::'
  REPLAY_TTL = 7.days

  def events
    case request.headers['X-Shopify-Topic']
    when 'customers/redact'
      compliance_safely('customers/redact') { redact_customer unless replayed_delivery? }
      head :ok
    when 'customers/data_request'
      compliance_safely('customers/data_request') { record_data_request unless replayed_delivery? }
      head :ok
    else
      super
    end
  end

  private

  def compliance_safely(topic)
    yield
  rescue StandardError => e
    begin
      ChatwootExceptionTracker.new(e).capture_exception
      Rails.logger.error("[umi-shopify-compliance] #{topic} handler failed (Shopify will NOT redeliver): #{e.message}")
    rescue StandardError
      # Shopify must still receive the deliberate 200. The retry job is
      # scheduled by the redaction path before this handler reports failure.
      nil
    end
  end

  # First sighting of this delivery id claims it atomically; anything else is a
  # replay (or a Shopify redelivery after a non-2xx, which is also safe to drop
  # because the first delivery already ran to a 200).
  def replayed_delivery?
    webhook_id = request.headers['X-Shopify-Webhook-Id']
    return false if webhook_id.blank?

    claimed = Redis::Alfred.set("#{REPLAY_KEY_PREFIX}#{webhook_id}", '1', nx: true, ex: REPLAY_TTL.to_i)
    Rails.logger.warn("[umi-shopify-compliance] dropped replayed delivery #{webhook_id}") unless claimed
    !claimed
  end

  def redact_customer
    account = compliance_account
    return if account.nil?

    payload = params[:customer] || {}
    contact, matched_by = find_redact_contact(account, payload)
    if contact.nil?
      Rails.logger.info("[umi-shopify-compliance] customers/redact: no contact for shopify customer #{payload[:id]} — nothing to do")
      return
    end

    apply_redaction(contact, matched_by)
    Rails.logger.info("[umi-shopify-compliance] customers/redact: contact #{contact.id} matched by #{matched_by} — " \
                      "#{redaction_action(contact, matched_by)} (shopify customer #{payload[:id]})")
  end

  # Hook gone (Shopify can deliver after uninstall; shop/redact deletes the
  # hook): fall back to the single account, but only for the expected shop —
  # see the module comment for why the pin is load-bearing.
  def compliance_account
    hook = Integrations::Hook.find_by(app_id: 'shopify', reference_id: params[:shop_domain])
    return hook.account if hook

    expected = ENV.fetch('UMI_SHOPIFY_SHOP_DOMAIN', nil)
    return Account.first if expected.present? && params[:shop_domain] == expected && Account.count == 1

    report_compliance_gap("cannot resolve account for shop #{params[:shop_domain]} " \
                          '(no hook; UMI_SHOPIFY_SHOP_DOMAIN unset or mismatched) — manual redaction required')
    nil
  end

  def find_redact_contact(account, payload)
    if payload[:id].present?
      contact = account.contacts.where("additional_attributes->>'shopify_customer_id' = ?", payload[:id].to_s).first
      return [contact, :shopify_customer_id] if contact
    end
    if payload[:email].present?
      contact = account.contacts.from_email(payload[:email])
      return [contact, :email] if contact
    end
    if payload[:phone].present?
      contact = account.contacts.find_by(phone_number: payload[:phone])
      return [contact, :phone] if contact
    end
    [nil, nil]
  end

  def redaction_action(contact, matched_by)
    return 'shopify attributes stripped (phone-only match, human review)' if matched_by == :phone

    contact.destroyed? ? 'destroyed' : 'anonymized'
  end

  def apply_redaction(contact, matched_by)
    if matched_by == :phone
      contact.update!(additional_attributes: contact.additional_attributes.reject { |key, _| key.start_with?('shopify_') })
      report_compliance_gap("customers/redact matched contact #{contact.id} by phone only — shopify attributes " \
                            'stripped, but PII kept; review whether full redaction applies')
    elsif contact.conversations.exists?
      anonymize_contact(contact)
    else
      contact.destroy!
    end
  end

  # A Meta DM contact stays identifiable through their Instagram handle and
  # profile photo, so erasure has to reach those too — blanking the name alone
  # is cosmetic. The avatar purge is synchronous rather than purge_later: a
  # queue that never drains would leave the image in place with nothing
  # reporting it.
  #
  # The tombstone outlives the erasure on purpose. Profile enrichment resolves
  # names and avatars from Meta on a recurring pass and would otherwise
  # re-derive both from the source_id, silently reversing a statutory erasure.
  # Keying that skip off the redacted name instead would not work — enrichment
  # renames the contact, which un-matches it.
  def anonymize_contact(contact)
    Umi::Shopify::CustomerRedactionService.new(contact).perform
  rescue StandardError => e
    begin
      Umi::Shopify::CustomerRedactionRetryJob.perform_later(contact.id)
    rescue StandardError => enqueue_error
      Rails.logger.error("[umi-shopify-compliance] could not enqueue redaction retry for contact #{contact.id}: " \
                         "#{enqueue_error.class}: #{enqueue_error.message}")
    end
    raise e
  end

  def record_data_request
    report_compliance_gap("Shopify customers/data_request for shop #{params[:shop_domain]}, " \
                          "customer #{params.dig(:customer, :id)} — manual export required (statutory deadline)")
  end

  # Statutory-deadline work must page, not rot in a log file.
  def report_compliance_gap(message)
    ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
    Rails.logger.error("[umi-shopify-compliance] #{message}")
  rescue StandardError
    nil
  end
end
# rubocop:enable Metrics/ModuleLength
