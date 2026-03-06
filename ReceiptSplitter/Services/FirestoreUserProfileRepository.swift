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
        let normalizedEmail = (user.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var data: [String: Any] = [
            "email": normalizedEmail,
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

    func fetchFriends(userID: String) async throws -> [AppFriend] {
        let snapshot = try await db
            .collection("users")
            .document(userID)
            .collection("friends")
            .order(by: "displayName")
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            let data = doc.data()
            let email = (data["email"] as? String) ?? ""
            let displayName = (data["displayName"] as? String) ?? ""
            let addedAt = (data["createdAt"] as? Timestamp)?.dateValue()
            return AppFriend(id: doc.documentID, email: email, displayName: displayName, addedAt: addedAt)
        }
    }

    func addFriend(currentUserID: String, friendEmail: String) async throws -> AppFriend {
        let normalizedFriendEmail = friendEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedFriendEmail.isEmpty else {
            throw NSError(
                domain: "Friends",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enter a valid friend email."]
            )
        }

        let userRef = db.collection("users").document(currentUserID)
        let currentUserSnapshot = try await userRef.getDocument()
        let currentUserData = currentUserSnapshot.data() ?? [:]
        let currentUserEmail = ((currentUserData["email"] as? String) ?? "").lowercased()
        let currentUserDisplayName = ((currentUserData["displayName"] as? String) ?? "")

        if normalizedFriendEmail == currentUserEmail {
            throw NSError(
                domain: "Friends",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "You cannot add yourself."]
            )
        }

        let lookupSnapshot = try await db
            .collection("users")
            .whereField("email", isEqualTo: normalizedFriendEmail)
            .limit(to: 1)
            .getDocuments()

        guard let friendDoc = lookupSnapshot.documents.first else {
            throw NSError(
                domain: "Friends",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No user found with that email."]
            )
        }

        let friendUserID = friendDoc.documentID
        guard friendUserID != currentUserID else {
            throw NSError(
                domain: "Friends",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "You cannot add yourself."]
            )
        }

        let friendData = friendDoc.data()
        let friendDisplayName = ((friendData["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let friendNameForList = friendDisplayName.isEmpty ? normalizedFriendEmail.components(separatedBy: "@").first ?? "Friend" : friendDisplayName
        let currentNameForList = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (currentUserEmail.components(separatedBy: "@").first ?? "Friend")
            : currentUserDisplayName

        let currentToFriendRef = db
            .collection("users")
            .document(currentUserID)
            .collection("friends")
            .document(friendUserID)
        let friendToCurrentRef = db
            .collection("users")
            .document(friendUserID)
            .collection("friends")
            .document(currentUserID)

        let batch = db.batch()
        batch.setData([
            "userId": friendUserID,
            "email": normalizedFriendEmail,
            "displayName": friendNameForList,
            "updatedAt": FieldValue.serverTimestamp(),
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: currentToFriendRef, merge: true)
        batch.setData([
            "userId": currentUserID,
            "email": currentUserEmail,
            "displayName": currentNameForList,
            "updatedAt": FieldValue.serverTimestamp(),
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: friendToCurrentRef, merge: true)
        try await batch.commit()

        return AppFriend(
            id: friendUserID,
            email: normalizedFriendEmail,
            displayName: friendNameForList,
            addedAt: Date()
        )
    }

    func removeFriend(currentUserID: String, friendUserID: String) async throws {
        let currentToFriendRef = db
            .collection("users")
            .document(currentUserID)
            .collection("friends")
            .document(friendUserID)
        let friendToCurrentRef = db
            .collection("users")
            .document(friendUserID)
            .collection("friends")
            .document(currentUserID)

        let batch = db.batch()
        batch.deleteDocument(currentToFriendRef)
        batch.deleteDocument(friendToCurrentRef)
        try await batch.commit()
    }
}
