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

protocol UserProfileRepository {
    func upsertUserProfile(for user: AppUser) async throws
    func fetchUserProfile(userID: String) async throws -> UserProfile?
    func updateDisplayName(userID: String, displayName: String) async throws
    func fetchFriends(userID: String) async throws -> [AppFriend]
    func addFriend(currentUserID: String, friendEmail: String) async throws -> AppFriend
    func removeFriend(currentUserID: String, friendUserID: String) async throws
}
