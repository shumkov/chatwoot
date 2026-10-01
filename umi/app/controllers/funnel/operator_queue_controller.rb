# frozen_string_literal: true

class Umi::Funnel::OperatorQueueController < Api::V1::Accounts::BaseController
  before_action :authorize_report
  rescue_from Umi::Funnel::OperatorQueue::InvalidParameters, with: :invalid_parameters

  def index
    render json: queue.index(after_id: params.fetch(:after_id, 0), through_id: params[:through_id])
  end

  def show
    render json: queue.show(params[:conversation_id])
  end

  private

  def authorize_report
    authorize Current.account, :update?
  end

  def queue
    Umi::Funnel::OperatorQueue.new(account_id: Current.account.id, since: params[:since])
  end

  def invalid_parameters
    render json: { error: 'Invalid operator queue parameters' }, status: :bad_request
  end
end
