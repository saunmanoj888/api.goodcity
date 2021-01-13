module Api
  module V1
    class StocktakesController < Api::V1::ApiController
      load_and_authorize_resource :stocktake, parent: false

      resource_description do
        short "List Stocktake Options"
        formats ["json"]
        error 401, "Unauthorized"
        error 404, "Not Found"
        error 422, "Validation Error"
        error 500, "Internal Server Error"
      end

      api :GET, "/v1/stocktakes", "List all stocktakes"
      def index
        render(
          json: @stocktakes,
          each_serializer: serializer,
          include_packages_locations: true,
          include_revisions: bool_param(:include_revisions, true)
        )
      end

      api :GET, "/v1/stocktakes/:id", "Get a stocktake by id"
      def show
        render(
          json: @stocktake,
          serializer: serializer,
          include_packages_locations: true,
          include_revisions: bool_param(:include_revisions, true)
        )
      end

      api :POST, "/v1/stocktakes", "Create a stocktake"
      def create
        raise Goodcity::DuplicateRecordError if Stocktake.find_by(name: stocktake_params['name']).present?
        
        @stocktake.created_by = current_user
        ActiveRecord::Base.transaction do
          success = @stocktake.save

          @stocktake.populate_revisions! if success

          if success
            render json: @stocktake, serializer: serializer, status: 201
          else
            render_error @stocktake.errors.full_messages.join(". ")
          end
        end
      end

      api :PUT, "/v1/stocktakes/:id/commit", "Processes a stocktake and tries to apply changes"
      def commit
        Stocktake.process_stocktake(@stocktake)
        render json: @stocktake, serializer: serializer, status: 200
      end

      api :PUT, "/v1/stocktakes/:id/cancel", "Cancels a stocktake"
      def cancel
        @stocktake.cancel if @stocktake.open?
        render json: @stocktake, serializer: serializer, status: 200
      end

      api :DELETE, "/v1/stocktakes/:id", "Deletes a stocktake and all its revisions"
      def destroy
        @stocktake.destroy!
        render json: {}, status: 200
      end

      private

      def stocktake_params
        attributes = [:location_id, :name, :comment]
        { state: 'open' }.merge(
          params.require(:stocktake).permit(attributes)
        )
      end

      def serializer
        Api::V1::StocktakeSerializer
      end

      def bool_param(key, default_val)
        return default_val unless params.include?(key)
        params[key].to_s == "true"
      end
    end
  end
end
