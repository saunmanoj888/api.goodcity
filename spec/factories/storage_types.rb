# frozen_String_literal: true

FactoryBot.define do
  factory :storage_type do
    name              { 'Box' }
    max_unit_quantity { ["Box", "Pallet"].include?(name) ? 1 : nil }
  end

  trait :with_box do
    name { 'Box' }
  end

  trait :with_pallet do
    name { 'Pallet' }
  end

  trait :with_pkg do
    name { 'Package' }
  end
end
