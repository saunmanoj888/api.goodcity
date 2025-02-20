# frozen_String_literal: true
require Rails.root.join('spec', 'support', 'inventory_initializer.rb')

FactoryBot.define do
  factory :package do
    length                { rand(199) + 1 }
    width                 { rand(199) + 1 }
    height                { rand(199) + 1 }
    weight                { rand(199) + 1 }
    pieces                { rand(199) + 1 }
    notes                 { "Notes" }
    state                 { 'expecting' }
    value_hk_dollar       { [10, 20, 30].sample }

    received_quantity     { storage_type&.singleton? ? 1 : 5 }
    on_hand_quantity      { received_quantity }
    available_quantity    { received_quantity }
    designated_quantity   { 0 }
    dispatched_quantity   { 0 }
    max_order_quantity    { nil }

    received_at { nil }
    rejected_at { nil }

    association :package_type
    association :donor_condition

    trait :with_item do
      association :item
    end

    trait :with_inventory_number do
      inventory_number      { InventoryNumber.next_code }
    end

    trait :with_inventory_record do
      inventory_number      { InventoryNumber.next_code }
      after(:create) do |package|
        InventoryInitializer.initialize_inventory(package)
      end
    end

    trait :package_with_locations do
      after(:create) do |package|
        build(:packages_location, package_id: package.id, quantity: package.received_quantity).sneaky do |package_location|
          package.location_id = package_location.location_id
          package.packages_locations ||= []
          package.packages_locations << package_location
          package.save
        end
      end
    end

    trait :dispatched do
      after(:create) do |package|
        InventoryInitializer.initialize_inventory(package)
        package.orders_packages = [
          create(
            :orders_package,
            :with_inventory_record,
            :with_state_dispatched,
            package_id: package.id,
            quantity: package.received_quantity
          )
        ]
      end
    end

    trait :received do
      with_inventory_record
      state { 'received' }
      received_at { Time.now }
    end

    trait :published do
      with_inventory_number
      allow_web_publish { true }
    end

    trait :unpublished do
      with_inventory_number
      allow_web_publish { false }
    end

    trait :with_images do
      images { create_list(:image, 2) }
    end

    trait :in_user_cart do
      after(:create) do |package, evaluator|
        package.requested_packages << (create :requested_package, package_id: package.id)
      end
    end

    factory :browseable_package, traits: [:published, :with_inventory_number, :received]
  end
end
