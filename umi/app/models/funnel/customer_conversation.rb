# frozen_string_literal: true

module Umi::Funnel::CustomerConversation
  extend ActiveSupport::Concern

  prepended do
    before_create :assign_initial_umi_customer_context
    after_create_commit :enqueue_initial_umi_customer_summary
    around_update :lock_umi_customer_status
    after_save :clear_umi_status_intent
  end

  def status=(value)
    super
    @umi_status_assigned = true if persisted? && Umi::Funnel::Configuration.customer_context_enabled?(account_id)
  end

  def update_labels(labels = nil)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    current = self.class.find(id)
    current.with_lock do
      self.label_list = current.label_list
      check_umi_labels!(Array(labels))
      before = label_list.to_a
      result = super
      Umi::Funnel::TopicCorrection.record!(self, before: before)
      result
    end
  end

  def add_labels(labels = nil)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)
    return if labels.blank?

    current = self.class.find(id)
    current.with_lock do
      self.label_list = current.label_list
      check_umi_incremental_labels!(Array(labels))
      update!(label_list: label_list | Array(labels))
    end
  end

  def remove_umi_labels!(labels)
    current = self.class.find(id)
    current.with_lock do
      self.label_list = current.label_list
      check_umi_incremental_labels!(labels)
      update!(label_list: label_list - labels)
    end
  end

  def check_umi_incremental_labels!(labels)
    return unless Array(labels).intersect?(Umi::Funnel::Configuration::PROTECTED_LABELS)

    raise ArgumentError, 'Customer, sales and source labels are managed; edit the corresponding attribute or fact'
  end

  def check_umi_labels!(labels)
    managed = Umi::Funnel::Configuration::PROTECTED_LABELS
    return if (label_list & managed).sort == (labels & managed).sort

    raise ArgumentError, 'Managed labels changed; refresh and edit the corresponding attribute or fact'
  end

  def toggle_status
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    current = self.class.find(id)
    current.with_lock do
      self.status = current.status
      clear_attribute_changes(['status'])
      super
    end
  end

  private

  def assign_initial_umi_customer_context
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    customer = Contact.find(contact_id)
    Umi::Funnel::CustomerProjection.assign(self, customer) unless customer.additional_attributes['umi_profile_redacted']
  end

  def enqueue_initial_umi_customer_summary
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    Umi::Funnel::CustomerProjectionJob.perform_later(contact_id, id)
  end

  def clear_umi_status_intent
    @umi_status_assigned = false
  end

  def lock_umi_customer_status # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
    return yield unless Umi::Funnel::Configuration.customer_context_enabled?(account_id) && (will_save_change_to_status? || @umi_status_assigned)

    # Lock a clean instance so the caller's assignee, snooze time and other dirty fields survive.
    current = self.class.find(id)
    current.with_lock do
      requested_status = status
      self.status = current.status
      clear_attribute_changes(['status'])
      self.status = requested_status
      next yield unless will_save_change_to_status?

      customer = Contact.find(contact_id)
      next yield if customer.additional_attributes['umi_profile_redacted']

      preserved_keys = [Umi::Funnel::CustomerProjection::KEY, *Umi::Funnel::OperatorResolution::KEYS]
      self.additional_attributes = current.additional_attributes.merge(additional_attributes.except(*preserved_keys))
      labels = label_list_changed? ? label_list : current.label_list
      Umi::Funnel::CustomerProjection.assign(self, customer, current_labels: labels)
      Umi::Funnel::CustomerProjection.summarize!(self, customer) if additional_attributes.dig(Umi::Funnel::CustomerProjection::KEY, 'summary')
      yield
    end
  end
end
