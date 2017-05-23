import PusherPlatform

public class PCRoom {
    public let id: Int
    public var name: String
    public let createdByUserId: Int
    public let createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
    public var userIds: [Int]

    public var subscription: PCRoomSubscription? = nil

    public init(
        id: Int,
        name: String,
        createdByUserId: Int,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil,
        userIds: [Int] = []
    ) {
        self.id = id
        self.name = name
        self.createdByUserId = createdByUserId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.userIds = userIds
    }

    internal func updateWithPropertiesOfRoom(_ room: PCRoom) {
        self.name = room.name
        self.updatedAt = room.updatedAt
        self.deletedAt = room.deletedAt
    }
}
