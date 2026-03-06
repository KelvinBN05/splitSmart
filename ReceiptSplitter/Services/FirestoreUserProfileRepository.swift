import Foundation
import FirebaseFirestore

final class FirestoreUserProfileRepository: UserProfileRepository {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func upsertUserProfile(for user: AppUser) async throws {
        let ref = db.collection("users").document(user.id)
        let snapshot = try await ref.getDocument()

        var data: [String: Any] = [
            "email": user.email ?? "",
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if snapshot.exists == false {
            data["createdAt"] = FieldValue.serverTimestamp()
        }

        try await ref.setData(data, merge: true)
    }

    func fetchUserProfile(userID: String) async throws -> UserProfile? {
        let ref = db.collection("users").document(userID)
        let snapshot = try await ref.getDocument()
        guard let data = snapshot.data() else { return nil }

        let email = (data["email"] as? String) ?? ""
        let displayName = (data["displayName"] as? String) ?? ""
        return UserProfile(userId: userID, email: email, displayName: displayName)
    }

    func updateDisplayName(userID: String, displayName: String) async throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ref = db.collection("users").document(userID)
        try await ref.setData([
            "displayName": trimmed,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }
}
