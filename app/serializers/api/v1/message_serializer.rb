module Api::V1

  class MessageSerializer < ActiveModel::Serializer
    embed :ids, include: true

    attributes :id, :body, :state, :recipient_id, :sender_id,
      :is_private, :created_at, :updated_at, :offer_id, :item_id

    has_one :sender, serializer: UserCompactSerializer, root: :user
    has_one :recipient, serializer: UserCompactSerializer, root: :user

  end

end
