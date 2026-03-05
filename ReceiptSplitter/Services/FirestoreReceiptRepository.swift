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

enum FirestoreReceiptMapper {
    static func encodeReceipt(_ receipt: Receipt, ownerUserId: String) -> [String: Any] {
        [
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
            tip: tip
        )
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
