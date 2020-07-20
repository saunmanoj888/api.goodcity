
module Api::V1
  class GcOrganisationsController < Api::V1::ApiController
    load_and_authorize_resource :organisation, parent: false

    resource_description do
      short "list, show organisations"
      formats ["json"]
      error 401, "Unauthorized"
      error 404, "Not Found"
      error 422, "Validation Error"
      error 500, "Internal Server Error"
    end

    api :GET, '/v1/organisations', "List all organisations"
    def index
      find_record_and_render_json(organisation_serializer)
    end

    api :GET, '/v1/organisations/1', "Details of a package"
    def show
      record = Api::V1::OrganisationSerializer.new(@organisation, root: "gc_organisations").as_json
      render json: record
    end

    api :GET, '/v1/organisations/names', "List all organisations names"
    def names
      find_record_and_render_json(organisation_name_serializer)
    end

    api :GET, '/v1/organisations/:id/orders', "List all orders associated with organisation"
    def orders
      organisation_orders = @organisation.orders
      orders = organisation_orders.page(page).per(per_page).order('id')
      meta = {
        total_pages: orders.total_pages,
        total_count: orders.size
      }
      render json: { meta: meta }.merge(
          serialized_orders(orders)
      )
    end

    private

    def organisation_serializer
      Api::V1::OrganisationSerializer
    end

    def organisation_name_serializer
      Api::V1::OrganisationNamesSerializer
    end

    def order_serializer
      Api::V1::OrderShallowSerializer
    end

    def serialized_orders(orders)
      ActiveModel::ArraySerializer.new(
        orders,
        each_serializer: order_serializer,
        root: "designations"
      ).as_json
    end

    def find_record_and_render_json(serializer)
      if params['ids'].present?
        records = @organisations.where(id: params['ids']).page(params["page"]).per(params["per_page"] || DEFAULT_SEARCH_COUNT)
      else
        records = @organisations.with_order.search(params["searchText"]).page(params["page"]).per(params["per_page"] || DEFAULT_SEARCH_COUNT)
      end
      data = ActiveModel::ArraySerializer.new(records, each_serializer: serializer, root: "gc_organisations").as_json
      render json: { "meta": { total_pages: records.total_pages, "search": params["searchText"] } }.merge(data)
    end
  end
end
