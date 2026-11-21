# frozen_string_literal: true

# UMI patch: one Shopify customer is carried by at most one contact per account.
#
# Binding means writing additional_attributes['shopify_customer_id'] = X on a
# contact that does not carry X yet. A second contact carrying X makes every
# paid event of X ambiguous (Umi::Funnel::PaidCustomerLink), so each binder
# refuses while another contact carries X. Writing X again on a contact that
# already carries it is a refresh and stays allowed, so contacts that already
# share a customer keep refreshing and are never unbound or moved.
#
# Every binder runs lock -> check -> write in one transaction. The advisory
# lock is held until commit, and under READ COMMITTED the next binder's check
# runs after that commit, so two binders of X cannot both pass the check.
#
# Lock order: a binder locks the contact row it binds BEFORE the customer lock
# (an UPDATE of an unlocked contact would take the row lock after it), and
# takes several customer locks only in ascending id order. Creating a new
# contact takes the customer lock alone. Design and proof:
# docs/UMI-SHOPIFY-SINGLE-BINDING-SPEC.md.
module Umi::Shopify::CustomerBinding
  LOCK_NAMESPACE = 'umi-shopify-customer'

  class << self
    def lock!(account_id, customer_ids)
      connection = Contact.connection
      # A transaction-level advisory lock taken in autocommit is released at
      # the end of its own statement and would guard nothing.
      raise ArgumentError, 'Shopify customer binding lock needs an open transaction' unless connection.transaction_open?

      customer_ids.map(&:to_s).uniq.sort.each do |customer_id|
        key = connection.quote("#{LOCK_NAMESPACE}:#{account_id}:#{customer_id}")
        connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{key}, 0))")
      end
    end

    # Locks the customer, then answers whether a contact other than `contact`
    # carries it. Call with the contact's row lock already held.
    def bound_elsewhere?(contact, customer_id)
      lock!(contact.account_id, [customer_id])
      others = carriers(contact.account_id, [customer_id]).where.not(id: contact.id).pluck(:id)
      return false if others.empty?

      Rails.logger.warn("[umi-customer-binding] contact #{contact.id} not bound to shopify customer #{customer_id}: " \
                        "already carried by contact(s) #{others.join(', ')}")
      true
    end

    # Customer ids among `customer_ids` that any contact carries, as strings.
    # Call after lock! for the same ids.
    def bound_customer_ids(account_id, customer_ids)
      carriers(account_id, customer_ids).distinct.pluck(Arel.sql("additional_attributes ->> 'shopify_customer_id'")).to_set
    end

    private

    # ->> returns text, so ids stored as JSON numbers (REST sync) and as
    # strings (GraphQL panel) compare equal.
    def carriers(account_id, customer_ids)
      Contact.where(account_id: account_id).where("additional_attributes ->> 'shopify_customer_id' IN (?)", customer_ids.map(&:to_s))
    end
  end
end
