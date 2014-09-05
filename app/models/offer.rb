class Offer < ActiveRecord::Base
  include Paranoid

  belongs_to :created_by, class_name: 'User', inverse_of: :offers
  has_many :messages, as: :recipient, dependent: :destroy
  has_many :items, inverse_of: :offer, dependent: :destroy
  has_one :delivery

  scope :submitted, -> { where(state: 'submitted') }

  scope :with_eager_load, -> {
    eager_load( [:created_by, { messages: :sender },
      { items: [:item_type, :rejection_reason, :donor_condition, :images,
               { messages: :sender }, { packages: :package_type }] }
    ])
  }

  state_machine :state, initial: :draft do
    state :submitted

    event :submit do
      transition :draft => :submitted
    end
  end

  def update_saleable_items
    items.update_saleable
  end
end
