class Offer < ActiveRecord::Base
  has_paper_trail class_name: 'Version'
  include Paranoid
  include StateMachineScope
  include PushUpdates

  INACTIVE_STATES = ["received", "closed", "cancelled"]

  belongs_to :created_by, class_name: 'User', inverse_of: :offers
  belongs_to :reviewed_by, class_name: 'User', inverse_of: :reviewed_offers
  belongs_to :closed_by, class_name: 'User'
  belongs_to :gogovan_transport
  belongs_to :crossroads_transport

  has_one  :delivery, dependent: :destroy
  has_many :items, inverse_of: :offer, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :users, through: :subscriptions

  validates :language, inclusion: { in: Proc.new { I18n.available_locales.map(&:to_s) } }, allow_nil: true

  accepts_nested_attributes_for :subscriptions

  scope :with_eager_load, -> {
    includes (
      [
        :created_by, :reviewed_by, :closed_by,
        { delivery: [:schedule, :contact] },
        { messages: :sender },
        { items: [:images, :packages, { messages: :sender } ] }
      ]
    )
  }

  scope :reviewed_by, ->(reviewed_by_id){ where(reviewed_by_id: reviewed_by_id) }
  scope :created_by, ->(created_by_id){ where(created_by_id: created_by_id) }
  scope :active, -> { where("state NOT IN (?)", INACTIVE_STATES) }
  scope :inactive, -> { where(state: INACTIVE_STATES) }
  scope :in_states, ->(states) { # overwrite concerns/state_machine_scope to add pseudo states
    states = [states].flatten.compact
    states.push(*Offer.inactive_states) if states.delete('inactive')
    states.push(*Offer.nondraft_states) if states.delete('nondraft')
    states.push(*Offer.active_states) if states.delete('active')
    states.push(*Offer.donor_valid_states) if states.delete('for_donor')
    where(state: states.uniq)
  }

  before_create :set_language
  after_initialize :set_initial_state

  # Workaround to set initial state fror the state_machine
  # StateMachine has Issue with rails 4.2, it does not set initial state by default
  # refer - https://github.com/pluginaweek/state_machine/issues/334
  def set_initial_state
    self.state ||= :draft
  end

  state_machine :state, initial: :draft do
    # todo rename 'reviewed' to 'awaiting_scheduling' to make it clear we only transition
    # to state when there are some accepted items
    state :submitted, :under_review, :reviewed, :scheduled, :closed, :received,
      :cancelled

    event :cancel do
      transition all => :cancelled, if: 'can_cancel?'
    end

    event :submit do
      transition :draft => :submitted
    end

    event :start_review do
      transition :submitted => :under_review
    end

    event :finish_review do
      transition :under_review => :reviewed
    end

    event :schedule do
      transition :reviewed => :scheduled
    end

    event :cancel_schedule do
      transition :scheduled => :reviewed
    end

    event :close do
      transition [:under_review, :reviewed, :scheduled] => :closed
    end

    event :receive do
      transition [:under_review, :reviewed, :scheduled] => :received
    end

    event :re_review do
      transition [:scheduled, :reviewed] => :under_review
    end

    before_transition :on => :submit do |offer, transition|
      offer.submitted_at = Time.now
    end

    before_transition :on => :start_review do |offer, transition|
      offer.reviewed_at = Time.now
    end

    before_transition :on => [:finish_review, :close] do |offer, transition|
      offer.review_completed_at = Time.now
    end

    before_transition :on => [:close, :cancel, :receive] do |offer, transition|
      offer.closed_by = User.current_user
    end

    before_transition :on => :receive do |offer, transition|
      offer.received_at = Time.now
    end

    before_transition :on => :cancel do |offer, transition|
      offer.cancelled_at = Time.now
    end

    after_transition :on => :submit do |offer, transition|
      offer.send_thank_you_message
      offer.send_new_offer_notification
      offer.send_new_offer_alert
    end

    after_transition on: :receive, do: :send_received_message

    after_transition :on => [:close, :re_review] do |offer, transition|
      if offer.try(:delivery).try(:gogovan_order).try(:status) != 'cancelled'
        offer.try(:delivery).try(:gogovan_order).try(:cancel_order)
      end
    end
  end

  class << self
    def donor_valid_states
      valid_states - ["cancelled"]
    end
    def inactive_states
      INACTIVE_STATES
    end
    def active_states
      valid_states - inactive_states
    end
    def nondraft_states
      valid_states - ["draft"]
    end
  end

  def gogovan_order
    self.try(:delivery).try(:gogovan_order)
  end

  def can_cancel?
    gogovan_order ? gogovan_order.can_cancel? : true
  end

  def clear_logistics_details
    update_attributes(crossroads_transport_id: nil, gogovan_transport_id: nil)
  end

  def send_thank_you_message
    messages.create(body: I18n.t("offer.thank_message"), sender: User.system_user)
  end

  def send_received_message
    messages.create(body: I18n.t("offer.received_message"), sender: User.system_user)
  end

  def send_item_add_message
    text = I18n.t("offer.item_add_message", donor_name: created_by.full_name)
    messages.create(sender: User.system_user, is_private: true, body: text)
    send_notification(text)
  end

  def update_saleable_items
    items.map(&:update_saleable)
  end

  def subscribed_users(is_private)
    Message.unscoped.joins(:subscriptions)
      .select("distinct subscriptions.user_id as user_id")
      .where(is_private: is_private, offer_id: id)
      .map(&:user_id)
  end

  def assign_reviewer(reviewer)
    update_attributes(
      reviewed_by_id: reviewer.id,
      state_event: 'start_review')
  end

  def send_new_offer_notification
    text = I18n.t("notification.new_offer", name: self.created_by.full_name)
    send_notification(text)
  end

  def send_new_offer_alert
    mobiles = (ENV['NEW_OFFER_ALERT_MOBILES'] || "").split(",").map(&:strip).compact
    if mobiles.any?
      User.where(mobile: mobiles).each do |user|
        TwilioService.new(user).new_offer_alert(self)
      end
    end
  end

  def send_ggv_cancel_order_message(ggv_time)
    message = cancel_message(ggv_time)
    messages.create(body: message, sender: User.system_user)
    send_notification(message)
  end

  def send_notification(text)
    PushService.new.send_notification(
      text: text,
      entity_type: "offer",
      entity: self,
      channel: Channel.reviewer)
  end

  private

  def cancel_message(time)
    text = I18n.t("offer.ggv_cancel_message", time: time, locale: "en")
    text += "<br/>"
    text += I18n.t("offer.ggv_cancel_message", time: time, locale: "zh-tw")
  end

  # Set a default offer language if it hasn't been set already
  def set_language
    self.language = I18n.locale.to_s unless self.language.present?
  end

  #required by PusherUpdates module
  def offer
    self
  end
end
