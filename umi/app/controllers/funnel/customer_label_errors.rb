# frozen_string_literal: true

module Umi::Funnel::CustomerLabelErrors
  def create
    super
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end
end
