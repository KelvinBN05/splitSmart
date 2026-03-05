import Foundation

protocol UserProfileRepository {
    func upsertUserProfile(for user: AppUser) async throws
}
