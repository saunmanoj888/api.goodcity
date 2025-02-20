module Api
  module V1
    class PackagesController < Api::V1::ApiController

      load_and_authorize_resource :package, parent: false
      skip_before_action :validate_token, only: [:index, :show]

      resource_description do
        short "Create, update and delete a package."
        formats ["json"]
        error 401, "Unauthorized"
        error 404, "Not Found"
        error 422, "Validation Error"
        error 500, "Internal Server Error"
      end

      def_param_group :package do
        param :package, Hash, required: true do
          param :quantity, lambda { |val| [String, Integer].include? val.class }, desc: "Package quantity", allow_nil: true
          param :received_quantity, lambda { |val| [String, Integer].include? val.class }, desc: "Package quantity", allow_nil: true
          param :length, lambda { |val| [String, Integer].include? val.class }, desc: "Package length", allow_nil: true
          param :width, lambda { |val| [String, Integer].include? val.class }, desc: "Package width", allow_nil: true
          param :height, lambda { |val| [String, Integer].include? val.class }, desc: "Package height", allow_nil: true
          param :notes, String, desc: "Comment mentioned by customer", allow_nil: true
          param :item_id, String, desc: "Item for which package is created", allow_nil: true
          param :state_event, Package.valid_events, allow_nil: true, desc: "Fires the state transition (if allowed) for this package."
          param :received_at, String, desc: "Date on which package is received", allow_nil: true
          param :rejected_at, String, desc: "Date on which package rejected", allow_nil: true
          param :package_type_id, lambda { |val| [String, Integer].include? val.class }, desc: "Category of the package", allow_nil: true
          param :favourite_image_id, lambda { |val| [String, Integer].include? val.class }, desc: "The id of the item image that represents this package", allow_nil: true
          param :donor_condition_id, lambda { |val| [String, Integer].include? val.class }, desc: "The id of donor-condition", allow_nil: true
          param :grade, String, allow_nil: true
          param :max_order_quantity, lambda { |val| [String, Integer].include? val.class }, desc: "Package max order quantity", allow_nil: true
        end
      end

      def_param_group :operations do
        param :quantity, [Integer, String], desc: "Package quantity", allow_nil: true
        param :order_id, [Integer, String], desc: "Order involved in the package's designation", allow_nil: true
        param :to, [Integer, String], desc: "Location the package is moved to", allow_nil: true
        param :from, [Integer, String], desc: "Location the package is moved from", allow_nil: true
        param :description, [Integer, String], desc: "Location the package is moved from", allow_nil: true
      end

      api :GET, "/v1/packages", "get all packages for the item"

      def index
        @packages = @packages.with_eager_load
        @packages = @packages.browse_public_packages if is_browse_app?
        @packages = @packages.where(inventory_number: params[:inventory_number].split(",")) if params[:inventory_number].present?
        @packages = @packages.find(params[:ids].split(",")) if params[:ids].present?
        @packages = @packages.search({ search_text: params["searchText"] })
          .page(page).per(per_page) if params["searchText"]
        render json: @packages, each_serializer: serializer,
          include_orders_packages: is_stock_app?,
          include_packages_locations: is_stock_app?,
          is_browse_app: is_browse_app?,
          exclude_set_packages: true,
          include_package_set: bool_param(:include_package_set, false)
      end

      api :GET, "/v1/packages/1", "Details of a package"

      def show
        render json: serializer.new(@package,
          include_orders_packages: true,
          include_packages_locations: true
        ).as_json
      end

      api :GET, "/v1/stockit_items/1", "Details of a stockit_item(package)"

      def stockit_item_details
        render json: stock_serializer
          .new(@package,
               serializer: stock_serializer,
               root: 'item',
               include_order: true,
               include_orders_packages: true,
               include_packages_locations: true,
               include_package_set: true,
               include_images: true,
               include_allowed_actions: true).as_json
      end

      api :POST, "/v1/packages", "Create a package"
      param_group :package

      def create
        # Callers
        # - Goodcity for create
        # - StockIt for create+update+designate+dispatch
        @package.inventory_number = remove_stockit_prefix(@package.inventory_number)

        success = ActiveRecord::Base.transaction do
          initialize_package_record
          quantity_changed = @package.received_quantity_changed?
          quantity_was = @package.received_quantity_was || 0
          if @package.valid? && @package.save
            try_inventorize_package(@package)
            true
          else
            false
          end
        end

        if success
          # @TODO: unify package under a single serializer
          if is_stock_app?
            render json: @package, serializer: stock_serializer, root: "item",
                    include_order: false,
                    include_orders_packages: true,
                    include_packages_locations: true
          else
            render json: @package, serializer: serializer, status: 201
          end
        else
          render json: { errors: @package.errors.full_messages }, status: 422
        end
      end

      api :PUT, "/v1/packages/1", "Update a package"
      param_group :package

      def update
        @package.assign_attributes(package_params)
        @package.detail = assign_detail if params["package"]["detail_type"].present?
        @package.received_quantity = package_params[:quantity] if package_params[:quantity].to_i.positive?
        @package.donor_condition_id = package_params[:donor_condition_id] if assign_donor_condition?
        @package.request_from_admin = is_admin_app?

        success = ActiveRecord::Base.transaction do
          if @package.valid? && @package.save
            try_inventorize_package(@package)
            true
          else
            false
          end
        end

        if success
          if is_stock_app?
            stockit_item_details
          else
            render json: @package, serializer: serializer,
              include_orders_packages: true,
              include_packages_locations: true
          end
        else
          render json: { errors: @package.errors.full_messages }, status: 422
        end
      end

      def assign_donor_condition?
        package_params[:donor_condition_id] && is_stock_app?
      end

      api :DELETE, "/v1/packages/1", "Delete an package"
      description "Deletion of the Package item in review mode"

      def destroy
        is_inventorized = PackagesInventory.where(package: @package).present?
        raise Goodcity::InventorizedPackageError if is_inventorized

        @package.really_destroy!
        render json: {}
      end

      api :PUT, "/v1/packages/1", "Mark a package as missing"
      def mark_missing
        ActiveRecord::Base.transaction do
          Package::Operations.uninventorize(@package) if PackagesInventory.inventorized?(@package)
          @package.mark_missing
        end
        render json: serializer.new(@package).as_json
      end

      api :POST, "/v1/packages/print_barcode", "Print barcode"

      def print_barcode
        return render json: { errors: I18n.t("package.max_print_error", max_barcode_qty: MAX_BARCODE_PRINT) }, status: 400 unless print_count.between?(1, MAX_BARCODE_PRINT)
        begin
          @package = Package.find params[:package_id]
        rescue ActiveRecord::RecordNotFound
          return render json: { errors: "Package not found with supplied package_id" }, status: 400
        end
        if @package.inventory_number.blank?
          @package.inventory_number = InventoryNumber.next_code
          @package.save
        end
        print_inventory_label
      end

      api :GET, '/v1/packages/package_valuation',
          'Get valuation of package based on its
           condition, grade and package type'
      param :donor_condition_id, [Integer, String], :required => true
      param :grade, String, :required => true
      param :package_type_id, [Integer, String], :required => true

      def package_valuation
        valuation = ValuationCalculationHelper.new(params['donor_condition_id'],
                                                   params['grade'],
                                                   params['package_type_id'])
                                              .calculate
        render json: { value_hk_dollar: valuation }, status: 200
      end

      def print_inventory_label
        printer = PrintersUser.where(user_id: current_user.id, tag: params[:tag]).first.try(:printer)
        return render json: { errors: I18n.t("package.printer_not_found") }, status: 400 unless printer
        opts = {
          print_count: print_count,
          label_type: "inventory_label"
        }
        PrintLabelJob.perform_later(@package.id, printer.id, opts)
        render json: {}, status: 204
      end

      api :GET, "/v1/packages/search_stockit_items", "Search packages (items for stock app) using inventory-number"

      def search_stockit_items
        records = @packages # security
        if params["searchText"].present?
          records = records.search(
            search_text: params["searchText"],
            item_id: params["itemId"],
            restrict_multi_quantity: params["restrictMultiQuantity"],
            with_inventory_no: true
          )
        end
        params_for_filter = %w[state location associated_package_types_for storage_type_name].each_with_object({}) { |k, h| h[k] = params[k].presence }
        records = records.apply_filter(params_for_filter)
        records = records.order("packages.id desc").page(params["page"]).per(params["per_page"] || DEFAULT_SEARCH_COUNT)
        packages = ActiveModel::ArraySerializer.new(records,
                                                    each_serializer: stock_serializer,
                                                    root: "items",
                                                    include_order: false,
                                                    include_packages: false,
                                                    include_orders_packages: true,
                                                    include_packages_locations: true,
                                                    include_package_set: bool_param(:include_package_set, true),
                                                    include_images: true).as_json
        render json: { meta: { total_pages: records.total_pages, search: params["searchText"] } }.merge(packages)
      end

      def split_package
        package_splitter = PackageSplitter.new(@package, qty_to_split)
        package_splitter.split!
        send_stock_item_response
      end

      api :PUT, "/v1/packages/1/move", "Move a package's quantity to an new location"
      param_group :operations
      def move
        quantity = params[:quantity].to_i
        Package::Operations.move(quantity, @package, from: params[:from], to: params[:to])
        send_stock_item_response
      end

      api :PUT, "/v1/packages/1/designate", "Designate a package's quantity to an order"
      param_group :operations
      def designate
        quantity = params[:quantity].to_i
        order_id = params[:order_id]
        shipping_number = params[:shipping_number].to_i

        Package::Operations.designate(@package,
          quantity: quantity,
          to_order: order_id,
          shipping_number: shipping_number)
        send_stock_item_response
      end

      api :PUT, "/v1/packages/1/actions/:action_name", "Executes an action on a package"
      param_group :operations

      def register_quantity_change
        Package::Operations.register_quantity_change(@package,
          quantity: params[:quantity].to_i,
          location: params[:from],
          action: params[:action_name],
          source: source,
          description: params[:description])

        send_stock_item_response
      end

      def remove_from_set
        @package.remove_from_set
        render json: @package, serializer: stock_serializer, root: "item",
          include_order: false
      end

      def send_stock_item_response
        @package.reload
        if @package.errors.blank? && @package.valid? && @package.save
          render json: stock_serializer.new(@package,
            root: "item",
            include_order: true,
            include_packages: false,
            include_allowed_actions: true,
            include_images: @package.package_set_id.blank?
          )
        else
          render json: { errors: @package.errors.full_messages }, status: 422
        end
      end

      def add_remove_item
        return head :no_content, status: 204 if params[:quantity].to_i.zero?

        response = Package::Operations.pack_or_unpack(
                    container: @package,
                    package: Package.find(params[:item_id]),
                    quantity: params[:quantity].to_i, # quantity to pack or unpack
                    location_id: params[:location_id],
                    user_id: User.current_user.id,
                    task: params[:task]
                  )
        if response[:success]
          render json: { packages_inventories: response[:packages_inventory] }, status: 201
        else
          render json: { errors: response[:errors] }, status: 422
        end
      end

      api :GET, "/v1/packages/1/contained_packages", "Returns the packages nested inside of current package"
      def contained_packages
        container = @package
        contained_pkgs = PackagesInventory.packages_contained_in(container).page(page)&.per(per_page)
        response = ActiveModel::ArraySerializer.new(contained_pkgs, each_serializer: stock_serializer,
          include_items: true,
          include_orders_packages: false,
          include_packages_locations: true,
          include_storage_type: false,
          include_donor_conditions: false,
          root: "items"
        ).as_json
        meta = { total_count: Package.total_quantity_in(container.id) }
        render json: { meta: meta }.merge(response)
      end

      api :GET, "/v1/packages/1/parent_containers", "Returns the packages which contain current package"
      def parent_containers
        containers = PackagesInventory.containers_of(@package).page(page)&.per(per_page)
        render json: containers,
          each_serializer: stock_serializer,
          include_items: true,
          include_orders_packages: false,
          include_packages_locations: false,
          include_storage_type: false,
          include_donor_conditions: false,
          include_images: true,
          root: "items"
      end

      def fetch_added_quantity
        entity_id = params[:entity_id]
        render json: { added_quantity: @package&.quantity_contained_in(entity_id) }, status: 200
      end

      api :GET, '/v1/packages/:id/versions', "List all versions associated with package"
      def versions
        subform_versions = @package.detail&.versions || []
        orders_package_versions = @package.orders_packages.reduce([]) { |op_versions, op| op_versions.concat(op.versions) }
        all_versions = @package.versions + subform_versions + orders_package_versions
        render json: all_versions, each_serializer: version_serializer, root: "versions"
      end

      private

      def render_order_status_error
        render json: { errors: I18n.t("orders_package.order_status_error") }, status: 403
      end

      def source
        ProcessingDestination.find_by(id: params[:processing_destination_id]) if params[:action_name] == PackagesInventory::Actions::PROCESS
      end

      def stock_serializer
        Api::V1::StockitItemSerializer
      end

      def version_serializer
        Api::V1::VersionSerializer
      end

      def remove_stockit_prefix(stockit_inventory_number)
        stockit_inventory_number.gsub(/^x/i, "") unless stockit_inventory_number.blank?
      end

      def package_params
        attributes = [
          :allow_web_publish, :box_id, :case_number, :designation_name,
          :detail_id, :detail_type, :donor_condition_id, :grade, :height,
          :inventory_number, :item_id, :length, :location_id, :notes,
          :notes_zh_tw, :order_id, :package_type_id, :pallet_id, :pieces,
          :received_at, :saleable, :received_quantity, :rejected_at,
          :state, :state_event, :stockit_designated_on, :max_order_quantity,
          :stockit_sent_on, :weight, :width, :favourite_image_id, :restriction_id,
          :comment, :expiry_date, :value_hk_dollar, :package_set_id, offer_ids: [],
          packages_locations_attributes: %i[id location_id quantity],
          detail_attributes: [:id, computer_attributes, electrical_attributes,
                              computer_accessory_attributes, medical_attributes].flatten.uniq
        ]

        params.require(:package).permit(attributes)
      end

      def qty_to_split
        (params["package"] && params["package"]["quantity"] || 0).to_i
      end

      # comp_test_status, frequency, test_status, voltage kept for stockit sync
      # will be removed later once we get rid of stockit
      def computer_attributes
        %i[
          brand comp_test_status comp_test_status_id comp_voltage country_id cpu
          hdd lan mar_ms_office_serial_num mar_os_serial_num model
          ms_office_serial_num optical os os_serial_num ram serial_num size
          sound updated_by_id usb video wireless
        ]
      end

      def electrical_attributes
        %i[
          brand country_id frequency frequency_id model power serial_number standard
          system_or_region test_status test_status_id tested_on updated_by_id
          voltage voltage_id
        ]
      end

      def computer_accessory_attributes
        %i[
          brand comp_test_status comp_test_status_id comp_voltage country_id
          interface model serial_num size updated_by_id
        ]
      end

      def medical_attributes
        %i[brand country_id serial_number updated_by_id]
      end

      def serializer
        Api::V1::PackageSerializer
      end

      def offer_id
        @package.try(:item).try(:offer_id)
      end

      def initialize_package_record
        if is_stock_app?
          @package.donor_condition_id = package_params[:donor_condition_id] if assign_donor_condition?
          @package.inventory_number = inventory_number
          @package
        elsif inventory_number
          assign_values_to_existing_or_new_package
        else
          @package.assign_attributes(package_params)
        end
        @package.storage_type = assign_storage_type
        @package.detail = assign_detail if params["package"]["detail_type"].present?
        @package.received_quantity ||= received_quantity
        @package.offer_id = offer_id
        @package
      end

      def try_inventorize_package(pkg)
        if pkg.inventory_number.present? && PackagesInventory.uninventorized?(pkg)
          raise Goodcity::BadOrMissingField.new('location_id') if pkg.location_id.blank?
          Package::Operations.inventorize(pkg, location_id)
        end
      end

      def assign_values_to_existing_or_new_package
        new_package_params = package_params
        @package = Package.new()
        delete_params_quantity_if_all_quantity_designated(new_package_params)
        @package.assign_attributes(new_package_params)
        @package.received_quantity = received_quantity
        @package.location_id = location_id
        @package.state = "received"
        @package.inventory_number = inventory_number
        @package
      end

      def print_count
        params[:labels].to_i
      end

      def received_quantity
        (params[:package][:received_quantity] || params[:package][:quantity]).to_i
      end

      def location_id
        package_params[:location_id]
      end

      def barcode_service
        BarcodeService.new
      end

      def assign_detail
        return if @package.box_or_pallet?

        PackageDetailBuilder.new(
          package_params
        ).build_or_update_record
      end

      def assign_storage_type
        storage_type_name = params["package"]["storage_type"] || "Package"
        return unless %w[Box Pallet Package].include?(storage_type_name)

        StorageType.find_by(name: storage_type_name)
      end

      def inventory_number
        remove_stockit_prefix(@package.inventory_number)
      end

      def delete_params_quantity_if_all_quantity_designated(new_package_params)
        if new_package_params["quantity"].to_i == @package.total_assigned_quantity
          new_package_params.delete("quantity")
        end
      end
    end
  end
end
