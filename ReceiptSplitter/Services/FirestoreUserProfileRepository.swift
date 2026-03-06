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
            "emailLower": normalizedEmail,
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
        let asSender = try await db
            .collection("friendRequests")
            .whereField("senderId", isEqualTo: userID)
            .whereField("status", isEqualTo: "accepted")
            .getDocuments()

        let asRecipient = try await db
            .collection("friendRequests")
            .whereField("recipientId", isEqualTo: userID)
            .whereField("status", isEqualTo: "accepted")
            .getDocuments()

        var friendsByID: [String: AppFriend] = [:]
        for doc in asSender.documents {
            guard let request = decodeFriendRequest(documentID: doc.documentID, data: doc.data()) else { continue }
            friendsByID[request.recipientId] = AppFriend(
                id: request.recipientId,
                email: request.recipientEmail,
                displayName: resolvedDisplayName(name: request.recipientDisplayName, email: request.recipientEmail),
                addedAt: request.updatedAt ?? request.createdAt
            )
        }

        for doc in asRecipient.documents {
            guard let request = decodeFriendRequest(documentID: doc.documentID, data: doc.data()) else { continue }
            friendsByID[request.senderId] = AppFriend(
                id: request.senderId,
                email: request.senderEmail,
                displayName: resolvedDisplayName(name: request.senderDisplayName, email: request.senderEmail),
                addedAt: request.updatedAt ?? request.createdAt
            )
        }

        return friendsByID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func fetchIncomingFriendRequests(userID: String) async throws -> [FriendRequest] {
        let snapshot = try await db
            .collection("friendRequests")
            .whereField("recipientId", isEqualTo: userID)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        return snapshot.documents.compactMap { decodeFriendRequest(documentID: $0.documentID, data: $0.data()) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func fetchOutgoingFriendRequests(userID: String) async throws -> [FriendRequest] {
        let snapshot = try await db
            .collection("friendRequests")
            .whereField("senderId", isEqualTo: userID)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        return snapshot.documents.compactMap { decodeFriendRequest(documentID: $0.documentID, data: $0.data()) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func sendFriendRequest(currentUserID: String, friendEmail: String) async throws {
        let normalizedFriendEmail = friendEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedFriendEmail.isEmpty else {
            throw NSError(domain: "Friends", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid friend email."])
        }

        let currentUserRef = db.collection("users").document(currentUserID)
        let currentUserSnap = try await currentUserRef.getDocument()
        let currentData = currentUserSnap.data() ?? [:]
        let currentEmail = ((currentData["emailLower"] as? String) ?? (currentData["email"] as? String) ?? "").lowercased()
        let currentDisplayName = resolvedDisplayName(
            name: (currentData["displayName"] as? String) ?? "",
            email: currentEmail
        )

        if normalizedFriendEmail == currentEmail {
            throw NSError(domain: "Friends", code: 2, userInfo: [NSLocalizedDescriptionKey: "You cannot add yourself."])
        }

        let friendDoc = try await findUserDocument(byEmailInput: friendEmail)
        guard let friendDoc else {
            throw NSError(
                domain: "Friends",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Account not found. Ask them to sign in once, then try again."]
            )
        }

        let friendUserID = friendDoc.documentID
        guard friendUserID != currentUserID else {
            throw NSError(domain: "Friends", code: 4, userInfo: [NSLocalizedDescriptionKey: "You cannot add yourself."])
        }

        let friendData = friendDoc.data()
        let friendEmailValue = ((friendData["emailLower"] as? String) ?? (friendData["email"] as? String) ?? normalizedFriendEmail).lowercased()
        let friendDisplayName = resolvedDisplayName(
            name: (friendData["displayName"] as? String) ?? "",
            email: friendEmailValue
        )

        let requestID = requestIDForPair(currentUserID, friendUserID)
        let requestRef = db.collection("friendRequests").document(requestID)
        let existing = try await requestRef.getDocument()

        if let existingData = existing.data(),
           let existingStatus = existingData["status"] as? String {
            if existingStatus == "accepted" {
                throw NSError(domain: "Friends", code: 5, userInfo: [NSLocalizedDescriptionKey: "You are already friends."])
            }
            if existingStatus == "pending", (existingData["senderId"] as? String) == currentUserID {
                throw NSError(domain: "Friends", code: 6, userInfo: [NSLocalizedDescriptionKey: "Friend request already sent."])
            }
            if existingStatus == "pending", (existingData["recipientId"] as? String) == currentUserID {
                throw NSError(domain: "Friends", code: 7, userInfo: [NSLocalizedDescriptionKey: "They already sent you a request. Approve it below."])
            }
        }

        try await requestRef.setData([
            "senderId": currentUserID,
            "senderEmail": currentEmail,
            "senderDisplayName": currentDisplayName,
            "recipientId": friendUserID,
            "recipientEmail": friendEmailValue,
            "recipientDisplayName": friendDisplayName,
            "members": [currentUserID, friendUserID],
            "status": "pending",
            "createdAt": existing.exists ? (existing.data()?["createdAt"] ?? FieldValue.serverTimestamp()) : FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "respondedAt": FieldValue.delete()
        ], merge: true)
    }

    func acceptFriendRequest(currentUserID: String, requestID: String) async throws {
        try await updateRequestStatus(currentUserID: currentUserID, requestID: requestID, to: "accepted")
    }

    func declineFriendRequest(currentUserID: String, requestID: String) async throws {
        try await updateRequestStatus(currentUserID: currentUserID, requestID: requestID, to: "declined")
    }

    func cancelOutgoingFriendRequest(currentUserID: String, requestID: String) async throws {
        let requestRef = db.collection("friendRequests").document(requestID)
        let snap = try await requestRef.getDocument()
        guard let data = snap.data() else { return }
        guard (data["senderId"] as? String) == currentUserID else {
            throw NSError(domain: "Friends", code: 8, userInfo: [NSLocalizedDescriptionKey: "Only sender can cancel this request."])
        }
        guard (data["status"] as? String) == "pending" else { return }

        try await requestRef.setData([
            "status": "canceled",
            "updatedAt": FieldValue.serverTimestamp(),
            "respondedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    private func updateRequestStatus(currentUserID: String, requestID: String, to status: String) async throws {
        let requestRef = db.collection("friendRequests").document(requestID)
        let snap = try await requestRef.getDocument()
        guard let data = snap.data() else { return }
        guard (data["recipientId"] as? String) == currentUserID else {
            throw NSError(domain: "Friends", code: 9, userInfo: [NSLocalizedDescriptionKey: "Only recipient can update this request."])
        }
        guard (data["status"] as? String) == "pending" else { return }

        try await requestRef.setData([
            "status": status,
            "updatedAt": FieldValue.serverTimestamp(),
            "respondedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    private func findUserDocument(byEmailInput input: String) async throws -> QueryDocumentSnapshot? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)

        let byLower = try await db
            .collection("users")
            .whereField("emailLower", isEqualTo: normalized)
            .limit(to: 1)
            .getDocuments()
        if let doc = byLower.documents.first {
            return doc
        }

        let byEmailLowered = try await db
            .collection("users")
            .whereField("email", isEqualTo: normalized)
            .limit(to: 1)
            .getDocuments()
        if let doc = byEmailLowered.documents.first {
            return doc
        }

        let byEmailRaw = try await db
            .collection("users")
            .whereField("email", isEqualTo: raw)
            .limit(to: 1)
            .getDocuments()
        return byEmailRaw.documents.first
    }

    private func decodeFriendRequest(documentID: String, data: [String: Any]) -> FriendRequest? {
        guard
            let senderId = data["senderId"] as? String,
            let recipientId = data["recipientId"] as? String,
            let status = data["status"] as? String
        else {
            return nil
        }

        let senderEmail = (data["senderEmail"] as? String) ?? ""
        let recipientEmail = (data["recipientEmail"] as? String) ?? ""
        let senderDisplayName = resolvedDisplayName(name: (data["senderDisplayName"] as? String) ?? "", email: senderEmail)
        let recipientDisplayName = resolvedDisplayName(name: (data["recipientDisplayName"] as? String) ?? "", email: recipientEmail)
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()

        return FriendRequest(
            id: documentID,
            senderId: senderId,
            senderEmail: senderEmail,
            senderDisplayName: senderDisplayName,
            recipientId: recipientId,
            recipientEmail: recipientEmail,
            recipientDisplayName: recipientDisplayName,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func requestIDForPair(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "__")
    }

    private func resolvedDisplayName(name: String, email: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email.components(separatedBy: "@").first ?? "Friend"
    }
}
