import Foundation

struct UserProfile: Equatable {
    let userId: String
    let email: String
    let displayName: String
}

protocol UserProfileRepository {
    func upsertUserProfile(for user: AppUser) async throws
    func fetchUserProfile(userID: String) async throws -> UserProfile?
    func updateDisplayName(userID: String, displayName: String) async throws
}
