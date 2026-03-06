import Foundation
import FirebaseFirestore

final class FirestoreReceiptRepository: ReceiptRepository {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func fetchReceipts(ownerUserId: String) async throws -> [Receipt] {
        let snapshot = try await db
            .collection("users")
            .document(ownerUserId)
            .collection("receipts")
            .getDocuments()

        return snapshot.documents.compactMap { document in
            FirestoreReceiptMapper.decodeReceipt(documentID: document.documentID, data: document.data())
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func saveReceipt(_ receipt: Receipt, ownerUserId: String) async throws {
        let data = FirestoreReceiptMapper.encodeReceipt(receipt, ownerUserId: ownerUserId)

        try await db
            .collection("users")
            .document(ownerUserId)
            .collection("receipts")
            .document(receipt.id.uuidString)
            .setData(data, merge: true)
    }
}

final class FirestoreSplitSessionRepository {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func createSession(from receipt: Receipt, ownerUserId: String, ownerDisplayName: String) async throws -> SplitSession {
        let sessionID = UUID().uuidString
        let sessionRef = db.collection("splitSessions").document(sessionID)

        let session = SplitSession(
            id: sessionID,
            ownerUserId: ownerUserId,
            sourceReceiptId: receipt.id.uuidString,
            sourceOCRJobID: receipt.sourceOCRJobID,
            merchantName: receipt.merchantName,
            createdAt: .now,
            updatedAt: .now,
            status: "draft",
            inviteCode: nil,
            readyUserIds: [],
            finalizedAt: nil,
            members: [
                SplitSessionMember(
                    id: ownerUserId,
                    displayName: ownerDisplayName,
                    role: "owner",
                    status: "accepted"
                )
            ],
            items: receipt.items.map { item in
                SplitSessionItem(
                    id: item.id.uuidString,
                    name: item.name,
                    quantity: item.quantity,
                    unitPrice: item.unitPrice,
                    assignedUserIds: [ownerUserId]
                )
            },
            totals: SplitSessionTotals(
                subtotal: receipt.subtotal,
                tax: receipt.tax,
                tip: receipt.tip,
                total: receipt.total
            )
        )

        let data = FirestoreSplitSessionMapper.encodeSession(session)
        let ownerSessionRef = db
            .collection("users")
            .document(ownerUserId)
            .collection("splitSessions")
            .document(sessionID)

        let batch = db.batch()
        batch.setData(data, forDocument: sessionRef, merge: true)
        batch.setData([
            "sessionId": sessionID,
            "merchantName": session.merchantName,
            "status": session.status,
            "updatedAt": Timestamp(date: session.updatedAt)
        ], forDocument: ownerSessionRef, merge: true)
        try await batch.commit()
        return session
    }

    func createInviteCode(sessionID: String, ownerUserId: String) async throws -> String {
        let code = String(UUID().uuidString.prefix(8)).uppercased()
        let inviteRef = db.collection("splitInvites").document(code)
        try await inviteRef.setData([
            "sessionId": sessionID,
            "ownerUserId": ownerUserId,
            "status": "active",
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(60 * 60 * 24 * 7))
        ], merge: true)

        try await db.collection("splitSessions").document(sessionID).setData([
            "inviteCode": code,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        return code
    }

    func joinSession(inviteCode: String, userId: String, userDisplayName: String) async throws -> SplitSession {
        let normalizedCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let inviteRef = db.collection("splitInvites").document(normalizedCode)
        let inviteSnap = try await inviteRef.getDocument()
        guard let inviteData = inviteSnap.data(),
              let sessionID = inviteData["sessionId"] as? String,
              let status = inviteData["status"] as? String,
              status == "active"
        else {
            throw NSError(domain: "SplitSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid or expired invite code."])
        }

        let sessionRef = db.collection("splitSessions").document(sessionID)
        try await db.runTransaction { transaction, errorPointer in
            do {
                let sessionSnap = try transaction.getDocument(sessionRef)
                guard var data = sessionSnap.data(),
                      let ownerUserId = data["ownerUserId"] as? String
                else {
                    throw NSError(domain: "SplitSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Session not found."])
                }

                var members = data["members"] as? [[String: Any]] ?? []
                if !members.contains(where: { ($0["id"] as? String) == userId }) {
                    members.append([
                        "id": userId,
                        "displayName": userDisplayName,
                        "role": "member",
                        "status": "accepted"
                    ])
                }
                data["members"] = members
                data["memberUserIds"] = members.compactMap { $0["id"] as? String }
                data["updatedAt"] = FieldValue.serverTimestamp()
                transaction.setData(data, forDocument: sessionRef, merge: true)

                let ownerSessionRef = self.db.collection("users").document(ownerUserId).collection("splitSessions").document(sessionID)
                transaction.setData([
                    "sessionId": sessionID,
                    "merchantName": data["merchantName"] as? String ?? "Split Session",
                    "status": data["status"] as? String ?? "draft",
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: ownerSessionRef, merge: true)

                let memberSessionRef = self.db.collection("users").document(userId).collection("splitSessions").document(sessionID)
                transaction.setData([
                    "sessionId": sessionID,
                    "merchantName": data["merchantName"] as? String ?? "Split Session",
                    "status": data["status"] as? String ?? "draft",
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: memberSessionRef, merge: true)

                return nil
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }

        let updated = try await db.collection("splitSessions").document(sessionID).getDocument()
        guard let session = FirestoreSplitSessionMapper.decodeSession(documentID: updated.documentID, data: updated.data() ?? [:]) else {
            throw NSError(domain: "SplitSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to load joined session."])
        }
        return session
    }

    func observeSession(sessionID: String, onChange: @escaping (SplitSession?) -> Void) -> ListenerRegistration {
        db.collection("splitSessions").document(sessionID).addSnapshotListener { snapshot, _ in
            guard let snapshot else {
                onChange(nil)
                return
            }
            let session = FirestoreSplitSessionMapper.decodeSession(documentID: snapshot.documentID, data: snapshot.data() ?? [:])
            onChange(session)
        }
    }

    func updateAssignments(sessionID: String, itemID: String, assignedUserIds: [String]) async throws {
        let sessionRef = db.collection("splitSessions").document(sessionID)
        let snap = try await sessionRef.getDocument()
        guard let data = snap.data() else { return }
        var items = data["items"] as? [[String: Any]] ?? []
        for index in items.indices {
            guard let id = items[index]["id"] as? String, id == itemID else { continue }
            items[index]["assignedUserIds"] = assignedUserIds
            break
        }
        try await sessionRef.setData([
            "items": items,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func setReadyState(sessionID: String, userId: String, isReady: Bool) async throws {
        let sessionRef = db.collection("splitSessions").document(sessionID)
        try await sessionRef.updateData([
            "readyUserIds": isReady ? FieldValue.arrayUnion([userId]) : FieldValue.arrayRemove([userId]),
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func finalizeSession(sessionID: String, ownerUserId: String) async throws {
        let sessionRef = db.collection("splitSessions").document(sessionID)
        let snap = try await sessionRef.getDocument()
        guard let data = snap.data(),
              let session = FirestoreSplitSessionMapper.decodeSession(documentID: snap.documentID, data: data)
        else { return }
        guard SplitSessionAccess.canFinalize(session, userId: ownerUserId) else {
            throw NSError(domain: "SplitSession", code: 4, userInfo: [NSLocalizedDescriptionKey: "All members must be ready before finalize."])
        }
        let updateData: [String: Any] = [
            "status": "finalized",
            "finalizedAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        try await sessionRef.setData(updateData, merge: true)

        let ownerSessionRef = db
            .collection("users")
            .document(ownerUserId)
            .collection("splitSessions")
            .document(sessionID)
        try await ownerSessionRef.setData([
            "status": "finalized",
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        // Keep joined users' session index in sync with session status.
        for memberID in session.members.map(\.id) where memberID != ownerUserId {
            let memberSessionRef = db
                .collection("users")
                .document(memberID)
                .collection("splitSessions")
                .document(sessionID)
            try await memberSessionRef.setData([
                "status": "finalized",
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }
}

enum FirestoreReceiptMapper {
    static func encodeReceipt(_ receipt: Receipt, ownerUserId: String) -> [String: Any] {
        var payload: [String: Any] = [
            "ownerUserId": ownerUserId,
            "merchantName": receipt.merchantName,
            "createdAt": Timestamp(date: receipt.createdAt),
            "tax": decimalString(receipt.tax),
            "tip": decimalString(receipt.tip),
            "participants": receipt.participants.map { participant in
                [
                    "id": participant.id.uuidString,
                    "name": participant.name
                ]
            },
            "items": receipt.items.map { item in
                [
                    "id": item.id.uuidString,
                    "name": item.name,
                    "quantity": item.quantity,
                    "unitPrice": decimalString(item.unitPrice),
                    "assignedParticipantIDs": Array(item.assignedParticipantIDs.map { $0.uuidString })
                ]
            }
        ]

        if let sourceOCRJobID = receipt.sourceOCRJobID, !sourceOCRJobID.isEmpty {
            payload["sourceOCRJobID"] = sourceOCRJobID
        }

        return payload
    }

    static func decodeReceipt(documentID: String, data: [String: Any]) -> Receipt? {
        guard
            let merchantName = data["merchantName"] as? String,
            let createdAtTimestamp = data["createdAt"] as? Timestamp,
            let taxRaw = data["tax"] as? String,
            let tipRaw = data["tip"] as? String,
            let tax = Decimal(string: taxRaw),
            let tip = Decimal(string: tipRaw),
            let participantsRaw = data["participants"] as? [[String: Any]],
            let itemsRaw = data["items"] as? [[String: Any]]
        else {
            return nil
        }

        let participants: [Participant] = participantsRaw.compactMap { raw in
            guard
                let idRaw = raw["id"] as? String,
                let id = UUID(uuidString: idRaw),
                let name = raw["name"] as? String
            else {
                return nil
            }
            return Participant(id: id, name: name)
        }

        let items: [ReceiptItem] = itemsRaw.compactMap { raw in
            guard
                let idRaw = raw["id"] as? String,
                let id = UUID(uuidString: idRaw),
                let name = raw["name"] as? String,
                let quantity = raw["quantity"] as? Int,
                let unitPriceRaw = raw["unitPrice"] as? String,
                let unitPrice = Decimal(string: unitPriceRaw),
                let assignedRaw = raw["assignedParticipantIDs"] as? [String]
            else {
                return nil
            }

            let assignedIDs = Set(assignedRaw.compactMap { UUID(uuidString: $0) })

            return ReceiptItem(
                id: id,
                name: name,
                quantity: quantity,
                unitPrice: unitPrice,
                assignedParticipantIDs: assignedIDs
            )
        }

        return Receipt(
            id: UUID(uuidString: documentID) ?? UUID(),
            merchantName: merchantName,
            createdAt: createdAtTimestamp.dateValue(),
            participants: participants,
            items: items,
            tax: tax,
            tip: tip,
            sourceOCRJobID: data["sourceOCRJobID"] as? String
        )
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

enum FirestoreSplitSessionMapper {
    static func encodeSession(_ session: SplitSession) -> [String: Any] {
        var payload: [String: Any] = [
            "ownerUserId": session.ownerUserId,
            "sourceReceiptId": session.sourceReceiptId,
            "merchantName": session.merchantName,
            "createdAt": Timestamp(date: session.createdAt),
            "updatedAt": Timestamp(date: session.updatedAt),
            "status": session.status,
            "memberUserIds": session.members.map(\.id),
            "readyUserIds": session.readyUserIds,
            "members": session.members.map { member in
                [
                    "id": member.id,
                    "displayName": member.displayName,
                    "role": member.role,
                    "status": member.status
                ]
            },
            "items": session.items.map { item in
                [
                    "id": item.id,
                    "name": item.name,
                    "quantity": item.quantity,
                    "unitPrice": decimalString(item.unitPrice),
                    "assignedUserIds": item.assignedUserIds
                ]
            },
            "totals": [
                "subtotal": decimalString(session.totals.subtotal),
                "tax": decimalString(session.totals.tax),
                "tip": decimalString(session.totals.tip),
                "total": decimalString(session.totals.total)
            ]
        ]

        if let sourceOCRJobID = session.sourceOCRJobID, !sourceOCRJobID.isEmpty {
            payload["sourceOCRJobID"] = sourceOCRJobID
        }
        if let inviteCode = session.inviteCode, !inviteCode.isEmpty {
            payload["inviteCode"] = inviteCode
        }
        if let finalizedAt = session.finalizedAt {
            payload["finalizedAt"] = Timestamp(date: finalizedAt)
        }

        return payload
    }

    static func decodeSession(documentID: String, data: [String: Any]) -> SplitSession? {
        guard
            let ownerUserId = data["ownerUserId"] as? String,
            let sourceReceiptId = data["sourceReceiptId"] as? String,
            let merchantName = data["merchantName"] as? String,
            let createdAtTimestamp = data["createdAt"] as? Timestamp,
            let updatedAtTimestamp = data["updatedAt"] as? Timestamp,
            let status = data["status"] as? String,
            let membersRaw = data["members"] as? [[String: Any]],
            let itemsRaw = data["items"] as? [[String: Any]],
            let totalsRaw = data["totals"] as? [String: String],
            let subtotal = Decimal(string: totalsRaw["subtotal"] ?? ""),
            let tax = Decimal(string: totalsRaw["tax"] ?? ""),
            let tip = Decimal(string: totalsRaw["tip"] ?? ""),
            let total = Decimal(string: totalsRaw["total"] ?? "")
        else {
            return nil
        }

        let members = membersRaw.compactMap { raw -> SplitSessionMember? in
            guard let id = raw["id"] as? String,
                  let displayName = raw["displayName"] as? String,
                  let role = raw["role"] as? String,
                  let status = raw["status"] as? String else {
                return nil
            }
            return SplitSessionMember(id: id, displayName: displayName, role: role, status: status)
        }

        let items = itemsRaw.compactMap { raw -> SplitSessionItem? in
            guard let id = raw["id"] as? String,
                  let name = raw["name"] as? String,
                  let quantity = raw["quantity"] as? Int,
                  let unitPriceString = raw["unitPrice"] as? String,
                  let unitPrice = Decimal(string: unitPriceString),
                  let assignedUserIds = raw["assignedUserIds"] as? [String] else {
                return nil
            }
            return SplitSessionItem(id: id, name: name, quantity: quantity, unitPrice: unitPrice, assignedUserIds: assignedUserIds)
        }

        let memberIDs = Set(members.map(\.id))
        let readyUserIds = (data["readyUserIds"] as? [String] ?? []).filter { memberIDs.contains($0) }

        return SplitSession(
            id: documentID,
            ownerUserId: ownerUserId,
            sourceReceiptId: sourceReceiptId,
            sourceOCRJobID: data["sourceOCRJobID"] as? String,
            merchantName: merchantName,
            createdAt: createdAtTimestamp.dateValue(),
            updatedAt: updatedAtTimestamp.dateValue(),
            status: status,
            inviteCode: data["inviteCode"] as? String,
            readyUserIds: readyUserIds,
            finalizedAt: (data["finalizedAt"] as? Timestamp)?.dateValue(),
            members: members,
            items: items,
            totals: SplitSessionTotals(subtotal: subtotal, tax: tax, tip: tip, total: total)
        )
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
