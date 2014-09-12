module Api::V1

  class MessageSerializer < ActiveModel::Serializer
    embed :ids, include: true

    attributes :id, :body, :recipient_id, :sender_id,
      :is_private, :created_at, :updated_at, :offer_id, :item_id

    has_one :sender, serializer: UserSerializer
    has_one :recipient, serializer: UserSerializer

  end

end
