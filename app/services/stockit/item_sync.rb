require 'stockit/base'

module Stockit
  class ItemSync

    include Stockit::Base

    attr_accessor :package, :errors, :offset, :per_page

    def initialize(package = nil, offset = nil, per_page = nil)
      @package = package
      @errors = {}
      @offset = offset
      @per_page = per_page
    end

    class << self
      def create(package)
        new(package).create
      end

      def update(package)
        new(package).update
      end

      def move(package)
        new(package).move
      end

      def undispatch(package)
        new(package).undispatch
      end

      def delete(package)
        new(package).delete
      end

      def index(package, offset, per_page)
        new(package, offset, per_page).index
      end

      # temporary method, to be removed after data import
      def index_with_detail(package, offset, per_page)
        new(package, offset, per_page).index_with_detail
      end

      def dispatch(package)
        new(package).dispatch
      end
    end

    def index
      url = url_for("/api/v1/items")
      get(url, { offset: offset, per_page: per_page })
    end

    # temporary method, to be removed after data import
    def index_with_detail
      url = url_for("/api/v1/items_with_detail")
      get(url, { offset: offset, per_page: per_page })
    end

    def create
      if package.inventory_number.present?
        url = url_for("/api/v1/items")
        post(url, stockit_params)
      end
    end

    def update
      if package.inventory_number.present?
        url = url_for("/api/v1/items/update")
        put(url, stockit_params)
      end
    end

    def move
      if package.inventory_number.present? && package.singleton_package?
        url = url_for("/api/v1/items/move")
        put(url, stockit_params)
      end
    end

    def delete
      inventory_number = package # package is actually inventory_number
      existing_package = inventory_number.present? && Package.find_by(inventory_number: inventory_number)
      if inventory_number.present? && existing_package
        url = url_for("/api/v1/items/destroy")
        put(url, { id: existing_package.stockit_id })
      end
    end

    def dispatch
      if package.inventory_number.present? && package.singleton_package?
        url = url_for("/api/v1/items/dispatch")
        put(url, stockit_params)
      end
    end

    def undispatch
      if package.inventory_number.present? && package.singleton_package?
        url = url_for("/api/v1/items/undispatch")
        put(url, stockit_params)
      end
    end

    private

    def add_stockit_prefix(inventory_number)
      return "X#{inventory_number}" if !!((inventory_number || "")[0..0] =~ /[0-9]/)
      inventory_number
    end

    def stockit_params
      {
        item: item_params,
        package: package_params
      }
    end

    def item_params
      {
        quantity: package.received_quantity,
        code_id: package.package_type.try(:stockit_id),
        inventory_number: add_stockit_prefix(package.inventory_number),
        case_number: package.case_number.blank? ? nil : package.case_number,
        condition: PackageConditionMapper.to_stockit(@package.donor_condition_name),
        grade: package.grade,
        description: package.notes,
        location_id: stockit_location_id,
        id: package.stockit_id,
        pieces: package.pieces,
        # designation_id: package.singleton_package? ? package.stockit_order_id : nil,
        # designated_on: package.singleton_package? ? package.stockit_designated_on : nil
        designation_id: package.stockit_order_id,
        designated_on: package.stockit_designated_on
      }
    end

    def package_params
      {
        length: package.length,
        width: package.width,
        height: package.height,
        weight: package.weight,
        description: package.notes
      }
    end

    # GoodCity doesn't keep location records for dispatched packages
    #   but Stockit likes to put them in the Dispatched location
    def stockit_location_id
      if package.stockit_sent_on.present? or package.orders_packages.where(state: 'dispatched').any?
        Location.dispatch_location.stockit_id
      elsif package.packages_locations.count > 1
        Location.multiple_location.try(:stockit_id)
      else
        package.locations.first.try(:stockit_id) || Location.find_by(id: package.location_id).try(:stockit_id)
      end
    end

  end
end
