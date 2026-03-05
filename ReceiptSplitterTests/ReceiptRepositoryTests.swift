import XCTest
import FirebaseFirestore
@testable import ReceiptSplitter

final class ReceiptRepositoryTests: XCTestCase {
    func testFirestoreReceiptMapperRoundTrip() {
        let ownerId = "owner-1"
        let participantA = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, name: "You")
        let participantB = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, name: "Sam")

        let receipt = Receipt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            merchantName: "Cafe Blue",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            participants: [participantA, participantB],
            items: [
                ReceiptItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                    name: "Nachos",
                    quantity: 2,
                    unitPrice: Decimal(string: "7.50")!,
                    assignedParticipantIDs: [participantA.id, participantB.id]
                )
            ],
            tax: Decimal(string: "1.25")!,
            tip: Decimal(string: "2.00")!
        )

        let encoded = FirestoreReceiptMapper.encodeReceipt(receipt, ownerUserId: ownerId)
        let decoded = FirestoreReceiptMapper.decodeReceipt(documentID: receipt.id.uuidString, data: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, receipt.id)
        XCTAssertEqual(decoded?.merchantName, receipt.merchantName)
        XCTAssertEqual(decoded?.participants.count, 2)
        XCTAssertEqual(decoded?.items.count, 1)
        XCTAssertEqual(decoded?.total, receipt.total)
    }

    func testFirestoreReceiptMapperDecodeFailsForMissingRequiredFields() {
        let invalidData: [String: Any] = [
            "merchantName": "Cafe Blue"
        ]

        let decoded = FirestoreReceiptMapper.decodeReceipt(
            documentID: UUID().uuidString,
            data: invalidData
        )

        XCTAssertNil(decoded)
    }

    func testFirestoreReceiptMapperKeepsAssignedParticipantIDs() {
        let participant = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!, name: "You")
        let receipt = Receipt(
            merchantName: "Test",
            participants: [participant],
            items: [
                ReceiptItem(
                    name: "Latte",
                    unitPrice: Decimal(string: "5.00")!,
                    assignedParticipantIDs: [participant.id]
                )
            ]
        )

        let encoded = FirestoreReceiptMapper.encodeReceipt(receipt, ownerUserId: "owner-2")
        let assignedRaw = ((encoded["items"] as? [[String: Any]])?.first?["assignedParticipantIDs"] as? [String]) ?? []

        XCTAssertEqual(assignedRaw.count, 1)
        XCTAssertEqual(assignedRaw.first, participant.id.uuidString)
    }
}
