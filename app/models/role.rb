class Role < ActiveRecord::Base
  include CacheableJson

  validates :name, uniqueness: true

  has_many :user_roles
  has_many :users, through: :user_roles
  has_many :role_permissions, dependent: :destroy
  has_many :permissions, through: :role_permissions

  scope :charity, ->{ where(name: 'Charity').first }
  scope :visible, ->{ where.not(name: 'api-write') }
  scope :allowed_roles, ->(level) { where("level <= ?", level) }
end
