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
        let sessionRef = db
            .collection("users")
            .document(ownerUserId)
            .collection("splitSessions")
            .document(sessionID)

        let session = SplitSession(
            id: sessionID,
            ownerUserId: ownerUserId,
            sourceReceiptId: receipt.id.uuidString,
            sourceOCRJobID: receipt.sourceOCRJobID,
            merchantName: receipt.merchantName,
            createdAt: .now,
            updatedAt: .now,
            status: "draft",
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
        try await sessionRef.setData(data, merge: true)
        return session
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

        return payload
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
