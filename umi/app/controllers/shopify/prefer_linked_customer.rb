# frozen_string_literal: true

# UMI patch: when a contact is already linked to a Shopify customer, render that
# customer's orders instead of searching for the customer all over again.
#
# Upstream resolves the sidebar's customer exclusively through
# customers/search.json on "email:<x> OR phone:<y>". But the customer → contact
# sync and the on-touch link (umi/app/controllers/shopify/persist_customer_link.rb)
# have already stored the id Shopify itself handed us on
# contact.additional_attributes['shopify_customer_id']. The controller never read
# it, so a contact we know is a customer still rendered an empty sidebar whenever
# the search failed to reproduce the match — a phone stored in a different shape
# on either side, an email an agent has since edited, an id inherited through a
# contact merge.
#
# The stored id is the stronger signal and is preferred whole: it was written
# from an exact match, while the search's OR-query can return a different
# customer first. When it is absent this falls through to upstream's search
# untouched.
#
# Returning a customer hash carrying only 'id' is sufficient for every consumer
# on this branch: the action reads `customers.first['id']` and fetch_orders sends
# it as the `customer_id` query param, taking nothing else from the record. The
# on-touch link prepend does read 'email'/'phone', but only when no id is stored
# — the branch that calls super and returns Shopify's real payload.
#
# No fallback to the search when the linked customer has no orders: Shopify
# answers orders.json for an unknown customer_id with an empty list, which is the
# same empty sidebar as today, and searching anyway would double the API calls on
# every render for every customer who has not ordered yet.
module Umi::Shopify::PreferLinkedCustomer
  private

  def fetch_customers
    linked_id = contact.additional_attributes['shopify_customer_id']
    return super if linked_id.blank?

    [{ 'id' => linked_id }]
  end
end
