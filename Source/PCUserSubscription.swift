import PusherPlatform

public class PCUserSubscription {

    // TODO: Do we need to be careful of retain cycles here?

    public let app: App
    public let resumableSubscription: PPResumableSubscription

    public internal(set) var delegate: PCChatManagerDelegate?

    public var connectCompletionHandlers: [(PCCurrentUser?, Error?) -> Void]

    public let userStore: PCUserStore

    public var currentUser: PCCurrentUser? = nil

    public init(
        app: App,
        resumableSubscription: PPResumableSubscription,
        userStore: PCUserStore,
        delegate: PCChatManagerDelegate? = nil,
        connectCompletionHandler: @escaping (PCCurrentUser?, Error?) -> Void
    ) {
        self.app = app
        self.resumableSubscription = resumableSubscription
        self.userStore = userStore
        self.delegate = delegate
        self.connectCompletionHandlers = [connectCompletionHandler]
    }

    public func handleEvent(eventId: String, headers: [String: String], data: Any) {
        guard let json = data as? [String: Any] else {
            self.app.logger.log("Failed to cast JSON object to Dictionary: \(data)", logLevel: .debug)
            return
        }

        guard let eventNameString = json["event_name"] as? String else {
            self.app.logger.log("Event name missing for API event: \(json)", logLevel: .debug)
            return
        }

        // TODO: Decide if we even need this in the client

        //        guard let timestamp = json["timestamp"] as? String else {
        //            return
        //        }

        guard let eventTypeString = json["event_type"] as? String else {
            self.app.logger.log("Event type missing for API event: \(json)", logLevel: .debug)
            return
        }

        guard let apiEventData = json["data"] as? [String: Any] else {
            self.app.logger.log("Data missing for API event: \(json)", logLevel: .debug)
            return
        }

        guard let eventName = PCAPIEventName(rawValue: eventNameString) else {
            self.app.logger.log("Unsupported API event name received: \(eventNameString)", logLevel: .debug)
            return
        }

        guard let eventType = PCAPIEventType(rawValue: eventTypeString) else {
            self.app.logger.log("Unsupported API event type received: \(eventTypeString)", logLevel: .debug)
            return
        }

        let userId = json["user_id"] as? Int

        if eventType == .user {
            guard userId != nil else {
                self.app.logger.log("user_id not received for API event: \(eventNameString)", logLevel: .debug)
                return
            }
        }

        self.app.logger.log("Received event type: \(eventTypeString), event name: \(eventNameString), and data: \(apiEventData)", logLevel: .verbose)

        switch eventName {
        case .initial_state:
            parseInitialStatePayload(eventName, data: apiEventData, userStore: self.userStore)
        case .added_to_room:
            parseAddedToRoomPayload(eventName, data: apiEventData)
        case .removed_from_room:
            parseRemovedFromRoomPayload(eventName, data: apiEventData)
        case .room_updated:
            parseRoomUpdatedPayload(eventName, data: apiEventData)
        case .room_deleted:
            parseRoomDeletedPayload(eventName, data: apiEventData)
        case .user_joined:
            parseUserJoinedPayload(eventName, data: apiEventData)
        case .user_left:
            parseUserLeftPayload(eventName, data: apiEventData)
        case .typing_start:
            parseTypingStartPayload(eventName, data: apiEventData, userId: userId!)
        case .typing_stop:
            parseTypingStopPayload(eventName, data: apiEventData, userId: userId!)

        // TODO: Remove?
//        case .new_room_message:
//            parseNewRoomMessagePayload(eventType, data: apiEventData)
        }
    }

    fileprivate func callConnectCompletionHandlers(currentUser: PCCurrentUser?, error: Error?) {
        for connectCompletionHandler in self.connectCompletionHandlers {
            connectCompletionHandler(currentUser, error)
        }
    }
}

extension PCUserSubscription {
    fileprivate func parseInitialStatePayload(_ eventName: PCAPIEventName, data: [String: Any], userStore: PCUserStore) {

        guard let roomsPayload = data["rooms"] as? [[String: Any]] else {
            callConnectCompletionHandlers(
                currentUser: nil,
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "rooms",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let userPayload = data["current_user"] as? [String: Any] else {
            callConnectCompletionHandlers(
                currentUser: nil,
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "user",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        let receivedCurrentUser: PCCurrentUser

        do {
            receivedCurrentUser = try PCPayloadDeserializer.createCurrentUserFromPayload(userPayload, app: self.app, userStore: userStore)
        } catch let err {
            callConnectCompletionHandlers(
                currentUser: nil,
                error: err
            )
            return
        }

        roomsPayload.forEach { roomPayload in
            guard let roomId = roomPayload["id"] as? Int,
                  let roomName = roomPayload["name"] as? String,
                  let roomCreatorUserId = roomPayload["created_by_id"] as? Int,
                  let roomCreatedAt = roomPayload["created_at"] as? String,
                  let roomUpdatedAt = roomPayload["updated_at"] as? String,
                  let memberships = roomPayload["memberships"] as? [[String: Any]]
            else {
                self.app.logger.log("Incomplete room payload in initial_state event: \(roomPayload)", logLevel: .debug)
                return
            }

            let room = PCRoom(
                id: roomId,
                name: roomName,
                createdByUserId: roomCreatorUserId,
                createdAt: roomCreatedAt,
                updatedAt: roomUpdatedAt
            )

            memberships.forEach { membership in
                guard let membershipUserId = membership["user_id"] as? Int else {
                    self.app.logger.log(
                        "Incomplete membership payload in initial_state event for room \(roomName): \(membership)",
                        logLevel: .debug
                    )
                    return
                }

                // TODO: Should we be fetching info about the users in the background here?
//                receivedCurrentUser.userStore.add(user)

                room.userIds.append(membershipUserId)
            }

            receivedCurrentUser.roomStore.add(room)
        }

        self.currentUser = receivedCurrentUser
        callConnectCompletionHandlers(currentUser: self.currentUser, error: nil)
    }

    fileprivate func parseAddedToRoomPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomPayload = data["room"] as? [String: Any] else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        do {
            let room = try PCPayloadDeserializer.createRoomFromPayload(roomPayload)
            self.currentUser?.roomStore.add(room)
            self.delegate?.addedToRoom(room: room)
        } catch let err {
            self.app.logger.log(err.localizedDescription, logLevel: .debug)
            self.delegate?.error(error: err)
        }
    }

    fileprivate func parseRemovedFromRoomPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let roomRemovedFrom = self.currentUser?.roomStore.remove(id: roomId) else {
            self.app.logger.log("Received \(eventName.rawValue) API event but room \(roomId) not found in local store of joined rooms", logLevel: .debug)
            return
        }

        self.delegate?.removedFromRoom(room: roomRemovedFrom)
    }

    fileprivate func parseRoomUpdatedPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomPayload = data["room"] as? [String: Any] else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        do {
            let room = try PCPayloadDeserializer.createRoomFromPayload(roomPayload)

            self.currentUser?.roomStore.room(id: room.id) { roomToUpdate, err in

                guard let roomToUpdate = roomToUpdate, err == nil else {
                    self.app.logger.log(err!.localizedDescription, logLevel: .debug)
                    return
                }

                roomToUpdate.updateWithPropertiesOfRoom(room)

                // TODO: Should this always be called?
                self.delegate?.roomUpdated(room: roomToUpdate)
            }
        } catch let err {
            self.app.logger.log(err.localizedDescription, logLevel: .debug)
            self.delegate?.error(error: err)
        }
    }

    fileprivate func parseRoomDeletedPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let currentUser = self.currentUser else {
            self.app.logger.log("currentUser property not set on PCUserSubscription", logLevel: .error)
            self.delegate?.error(error: PCError.currentUserIsNil)
            return
        }

        guard let deletedRoom = currentUser.roomStore.remove(id: roomId) else {
            self.app.logger.log("Room \(roomId) was deleted but was not found in local store of joined rooms", logLevel: .debug)
            return
        }

        self.delegate?.roomDeleted(room: deletedRoom)
    }

    fileprivate func parseUserJoinedPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let userId = data["user_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "user_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let currentUser = self.currentUser else {
            self.app.logger.log("currentUser property not set on PCUserSubscription", logLevel: .error)
            self.delegate?.error(error: PCError.currentUserIsNil)
            return
        }

        currentUser.roomStore.room(id: roomId) { room, err in
            guard let room = room, err == nil else {
                self.app.logger.log(
                    "User with id \(userId) joined room with id \(roomId) but no information about the room could be retrieved. Error was: \(err!.localizedDescription)",
                    logLevel: .error
                )
                self.delegate?.error(error: err!)
                return
            }

            currentUser.userStore.user(id: userId) { user, err in
                guard let user = user, err == nil else {
                    self.app.logger.log(
                        "User with id \(userId) joined room with id \(roomId) but no information about the user could be retrieved. Error was: \(err!.localizedDescription)",
                        logLevel: .error
                    )
                    self.delegate?.error(error: err!)
                    return
                }

                room.userIds.append(user.id)

                self.delegate?.userJoinedRoom(room: room, user: user)
                room.subscription?.delegate?.userJoined(user: user)
            }
        }
    }

    fileprivate func parseUserLeftPayload(_ eventName: PCAPIEventName, data: [String: Any]) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let userId = data["user_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "user_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let currentUser = self.currentUser else {
            self.app.logger.log("currentUser property not set on PCUserSubscription", logLevel: .error)
            self.delegate?.error(error: PCError.currentUserIsNil)
            return
        }

        currentUser.roomStore.room(id: roomId) { room, err in
            guard let room = room, err == nil else {
                self.app.logger.log(
                    "User with id \(userId) left room with id \(roomId) but no information about the room could be retrieved. Error was: \(err!.localizedDescription)",
                    logLevel: .error
                )
                self.delegate?.error(error: err!)
                return
            }

            currentUser.userStore.user(id: userId) { user, err in
                guard let user = user, err == nil else {
                    self.app.logger.log(
                        "User with id \(userId) left room with id \(roomId) but no information about the user could be retrieved. Error was: \(err!.localizedDescription)",
                        logLevel: .error
                    )
                    self.delegate?.error(error: err!)
                    return
                }

                let roomUserIdIndex = room.userIds.index(of: user.id)

                if let indexToRemove = roomUserIdIndex {
                    room.userIds.remove(at: indexToRemove)
                }

                self.delegate?.userLeftRoom(room: room, user: user)
                room.subscription?.delegate?.userLeft(user: user)
            }
        }
    }

    fileprivate func parseTypingStartPayload(_ eventName: PCAPIEventName, data: [String: Any], userId: Int) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let currentUser = self.currentUser else {
            self.app.logger.log("currentUser property not set on PCUserSubscription", logLevel: .error)
            self.delegate?.error(error: PCError.currentUserIsNil)
            return
        }

        currentUser.roomStore.room(id: roomId) { room, err in
            guard let room = room, err == nil else {
                self.app.logger.log(err!.localizedDescription, logLevel: .error)
                self.delegate?.error(error: err!)
                return
            }

            currentUser.userStore.user(id: userId) { user, err in
                guard let user = user, err == nil else {
                    self.app.logger.log(err!.localizedDescription, logLevel: .error)
                    self.delegate?.error(error: err!)
                    return
                }

                self.delegate?.userStartedTyping(room: room, user: user)
                room.subscription?.delegate?.userStartedTyping(user: user)
            }
        }


    }


    fileprivate func parseTypingStopPayload(_ eventName: PCAPIEventName, data: [String: Any], userId: Int) {
        guard let roomId = data["room_id"] as? Int else {
            self.delegate?.error(
                error: PCAPIEventError.keyNotPresentInPCAPIEventPayload(
                    key: "room_id",
                    apiEventName: eventName,
                    payload: data
                )
            )
            return
        }

        guard let currentUser = self.currentUser else {
            self.app.logger.log("currentUser property not set on PCUserSubscription", logLevel: .error)
            self.delegate?.error(error: PCError.currentUserIsNil)
            return
        }

        currentUser.roomStore.room(id: roomId) { room, err in
            guard let room = room, err == nil else {
                self.app.logger.log(err!.localizedDescription, logLevel: .error)
                self.delegate?.error(error: err!)
                return
            }

            currentUser.userStore.user(id: userId) { user, err in
                guard let user = user, err == nil else {
                    self.app.logger.log(err!.localizedDescription, logLevel: .error)
                    self.delegate?.error(error: err!)
                    return
                }

                self.delegate?.userStoppedTyping(room: room, user: user)
                room.subscription?.delegate?.userStoppedTyping(user: user)
            }
        }

    }


    // TODO: Remove?

    //    fileprivate func parseNewRoomMessagePayload(_ eventName: PCAPIEventName, data: [String: Any]) {
    //        guard let messagePayload = data["message"] as? [String: Any] else {
    //            self.delegate?.error(
    //                PCAPIEventError.keyNotPresentInPCAPIEventPayload(
    //                    key: "message",
    //                    apiEventName: eventName,
    //                    payload: data
    //                )
    //            )
    //            return
    //        }
    //
    //        do {
    //            let message = try PCPayloadDeserializer.createMessageFromPayload(messagePayload)
    //
    //            guard let roomWithNewMessage = self.currentUser?.rooms.first(where: { $0.id == message.roomId }) else {
    //                // TODO: Log and call delelgate?.error() ?
    //                return
    //            }
    //
    //            roomWithNewMessage.messages.append(message)
    //            self.delegate?.messageReceived(room: roomWithNewMessage, message: message)
    //        } catch let err {
    //            self.app.logger.log(err.localizedDescription, logLevel: .debug)
    //            self.delegate?.error(err)
    //        }
    //    }
}

public enum PCAPIEventError: Error {
    case eventTypeNameMissingInAPIEventPayload([String: Any])
    case apiEventDataMissingInAPIEventPayload([String: Any])
    case keyNotPresentInPCAPIEventPayload(key: String, apiEventName: PCAPIEventName, payload: [String: Any])
}

extension PCAPIEventError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .eventTypeNameMissingInAPIEventPayload(let payload):
            return "Event type missing in API event payload: \(payload)"
        case .apiEventDataMissingInAPIEventPayload(let payload):
            return "Data missing in API event payload: \(payload)"
        case .keyNotPresentInPCAPIEventPayload(let key, let apiEventName, let payload):
            return "\(key) missing in \(apiEventName.rawValue) API event payload: \(payload)"
        }
    }
}

public enum PCError: Error {
    case invalidJSONObjectAsData(Any)
    case failedToJSONSerializeData(Any)

    case failedToDeserializeJSON(Data)
    case failedToCastJSONObjectToDictionary(Any)


    // TODO: Where do these belong?!


    case userIdNotFoundInResponseJSON([String: Any])

    case roomCreationResponsePayloadIncomplete([String: Any])


    case incompleteRoomPayloadInGetRoomResponse([String: Any])

    case messageIdKeyMissingInMessageCreationResponse([String: Int])

    case currentUserIsNil
}

extension PCError: LocalizedError {

}

public enum PCAPIEventType: String {
    case api
    case user
}

public enum PCAPIEventName: String {
    // TODO: Remove?
    //    case new_room_message

    case initial_state
    case added_to_room
    case removed_from_room
    case room_updated
    case room_deleted
    case user_joined
    case user_left
    case typing_start
    case typing_stop
}

public enum PCUserSubscriptionState {
    case opening
    case open
    case resuming
    case end(statusCode: Int?, headers: [String: String]?, info: Any?)
    case error(error: Error)
}
