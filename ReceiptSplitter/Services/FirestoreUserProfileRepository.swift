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
}
