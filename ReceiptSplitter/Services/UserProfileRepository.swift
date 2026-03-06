import Foundation

struct UserProfile: Equatable {
    let userId: String
    let email: String
    let displayName: String
}

struct AppFriend: Identifiable, Equatable {
    let id: String
    let email: String
    let displayName: String
    let addedAt: Date?
}

struct FriendRequest: Identifiable, Equatable {
    let id: String
    let senderId: String
    let senderEmail: String
    let senderDisplayName: String
    let recipientId: String
    let recipientEmail: String
    let recipientDisplayName: String
    let status: String
    let createdAt: Date?
    let updatedAt: Date?
}

protocol UserProfileRepository {
    func upsertUserProfile(for user: AppUser) async throws
    func fetchUserProfile(userID: String) async throws -> UserProfile?
    func updateDisplayName(userID: String, displayName: String) async throws
    func fetchFriends(userID: String) async throws -> [AppFriend]
    func fetchIncomingFriendRequests(userID: String) async throws -> [FriendRequest]
    func fetchOutgoingFriendRequests(userID: String) async throws -> [FriendRequest]
    func sendFriendRequest(currentUserID: String, friendEmail: String) async throws
    func acceptFriendRequest(currentUserID: String, requestID: String) async throws
    func declineFriendRequest(currentUserID: String, requestID: String) async throws
    func cancelOutgoingFriendRequest(currentUserID: String, requestID: String) async throws
}
