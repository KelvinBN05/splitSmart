import Foundation
import FirebaseFirestore

final class FirestoreUserProfileRepository: UserProfileRepository {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func upsertUserProfile(for user: AppUser) async throws {
        let data: [String: Any] = [
            "email": user.email ?? "",
            "updatedAt": FieldValue.serverTimestamp(),
            "createdAt": FieldValue.serverTimestamp()
        ]

        try await db.collection("users").document(user.id).setData(data, merge: true)
    }
}
