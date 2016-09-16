module Api::V1
  class OrdersController < Api::V1::ApiController

    load_and_authorize_resource :order, parent: false
    before_action :eager_load_designation, only: :show

    resource_description do
      short 'Retrieve a list of designations, information about stock items that have been designated to a group or person.'
      formats ['json']
      error 401, "Unauthorized"
      error 404, "Not Found"
      error 422, "Validation Error"
      error 500, "Internal Server Error"
    end

    def_param_group :order do
      param :order, Hash, required: true do
        param :status, String
        param :code, String
        param :created_at, String
        param :stockit_contact_id, String
        param :stockit_organisation_id, String
        param :detail_id, String
        param :stockit_id, String, desc: "stockit designation record id"
      end
    end

    api :POST, "/v1/orders", "Create or Update a order"
    param_group :order
    def create
      if order_record.save
        render json: @order, serializer: serializer, status: 201
      else
        render json: @order.errors.to_json, status: 422
      end
    end

    api :GET, '/v1/orders', "List all orders"
    def index
      return recent_designations if params['recently_used'].present?
      records = @orders.with_eager_load.
        search(params['searchText'], params['toDesignateItem'].presence).latest.
        page(params["page"]).per(params["per_page"])
      orders = ActiveModel::ArraySerializer.new(records, each_serializer: serializer, root: "designations", exclude_stockit_set_item: true).to_json
      render json: orders.chop + ",\"meta\":{\"total_pages\": #{records.total_pages}, \"search\": \"#{params['searchText']}\"}}"
    end

    api :GET, '/v1/designations/1', "Get a order"
    def show
      render json: @order, serializer: serializer, root: "designation", exclude_code_details: true
    end

    def recent_designations
      records = Order.recently_used(User.current_user.id)
      orders = ActiveModel::ArraySerializer.new(records, each_serializer: serializer, root: "designations", exclude_stockit_set_item: true).to_json
      render json: orders
    end

    private

    def order_record
      @order = Order.where(stockit_id: order_params[:stockit_id]).first_or_initialize
      @order.assign_attributes(order_params)
      @order.stockit_activity = stockit_activity
      @order.stockit_contact = stockit_contact
      @order.stockit_organisation = stockit_organisation
      @order.detail = stockit_local_order
      @order
    end

    def order_params
      params.require(:order).permit(:stockit_id, :code, :status, :created_at, :stockit_contact_id, :detail_id, :detail_type, :stockit_organisation_id, :description, :stockit_activity_id)
    end

    def serializer
      Api::V1::OrderSerializer
    end

    def stockit_activity
      StockitActivity.find_by(stockit_id: params["order"]["stockit_activity_id"])
    end

    def stockit_contact
      StockitContact.find_by(stockit_id: params["order"]["stockit_contact_id"])
    end

    def stockit_organisation
      StockitOrganisation.find_by(stockit_id: params["order"]["stockit_organisation_id"])
    end

    def stockit_local_order
      StockitLocalOrder.find_by(stockit_id: params["order"]["detail_id"])
    end

    def eager_load_designation
      @order = Order.with_eager_load.find(params[:id])
    end

  end
end
