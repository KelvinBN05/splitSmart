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
            tip: Decimal(string: "2.00")!,
            sourceOCRJobID: "OCR-JOB-123"
        )

        let encoded = FirestoreReceiptMapper.encodeReceipt(receipt, ownerUserId: ownerId)
        let decoded = FirestoreReceiptMapper.decodeReceipt(documentID: receipt.id.uuidString, data: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, receipt.id)
        XCTAssertEqual(decoded?.merchantName, receipt.merchantName)
        XCTAssertEqual(decoded?.participants.count, 2)
        XCTAssertEqual(decoded?.items.count, 1)
        XCTAssertEqual(decoded?.total, receipt.total)
        XCTAssertEqual(decoded?.sourceOCRJobID, "OCR-JOB-123")
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

    func testFirestoreSplitSessionMapperEncodesCoreFields() {
        let session = SplitSession(
            id: "session-1",
            ownerUserId: "owner-1",
            sourceReceiptId: "receipt-1",
            sourceOCRJobID: "ocr-job-1",
            merchantName: "Target",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            status: "draft",
            inviteCode: "ABCDEFGH",
            readyUserIds: ["owner-1"],
            finalizedAt: nil,
            members: [
                SplitSessionMember(id: "owner-1", displayName: "owner@example.com", role: "owner", status: "accepted")
            ],
            items: [
                SplitSessionItem(id: "item-1", name: "Milk", quantity: 2, unitPrice: Decimal(string: "3.49")!, assignedUserIds: ["owner-1"])
            ],
            totals: SplitSessionTotals(
                subtotal: Decimal(string: "6.98")!,
                tax: Decimal(string: "0.56")!,
                tip: Decimal.zero,
                total: Decimal(string: "7.54")!
            )
        )

        let payload = FirestoreSplitSessionMapper.encodeSession(session)

        XCTAssertEqual(payload["ownerUserId"] as? String, "owner-1")
        XCTAssertEqual(payload["sourceReceiptId"] as? String, "receipt-1")
        XCTAssertEqual(payload["sourceOCRJobID"] as? String, "ocr-job-1")
        XCTAssertEqual(payload["merchantName"] as? String, "Target")
        XCTAssertEqual(payload["status"] as? String, "draft")
        XCTAssertEqual(payload["inviteCode"] as? String, "ABCDEFGH")
        XCTAssertEqual(payload["readyUserIds"] as? [String], ["owner-1"])
        XCTAssertEqual(payload["memberUserIds"] as? [String], ["owner-1"])
        XCTAssertEqual((payload["members"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((payload["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((payload["totals"] as? [String: String])?["total"], "7.54")
    }

    func testFirestoreSplitSessionMapperOmitsEmptySourceOCRJobID() {
        let session = SplitSession(
            id: "session-2",
            ownerUserId: "owner-1",
            sourceReceiptId: "receipt-1",
            sourceOCRJobID: nil,
            merchantName: "Cafe",
            createdAt: .now,
            updatedAt: .now,
            status: "draft",
            inviteCode: nil,
            readyUserIds: [],
            finalizedAt: nil,
            members: [],
            items: [],
            totals: .init(subtotal: 0, tax: 0, tip: 0, total: 0)
        )

        let payload = FirestoreSplitSessionMapper.encodeSession(session)
        XCTAssertNil(payload["sourceOCRJobID"])
    }

    func testFirestoreSplitSessionMapperDecodeRoundTrip() throws {
        let session = SplitSession(
            id: "session-3",
            ownerUserId: "owner-2",
            sourceReceiptId: "receipt-2",
            sourceOCRJobID: "ocr-job-2",
            merchantName: "La Cabana",
            createdAt: Date(timeIntervalSince1970: 1_700_000_300),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400),
            status: "finalized",
            inviteCode: "ZXCVBN12",
            readyUserIds: ["owner-2", "friend-1"],
            finalizedAt: Date(timeIntervalSince1970: 1_700_000_500),
            members: [
                SplitSessionMember(id: "owner-2", displayName: "owner@example.com", role: "owner", status: "accepted"),
                SplitSessionMember(id: "friend-1", displayName: "friend@example.com", role: "member", status: "accepted")
            ],
            items: [
                SplitSessionItem(id: "item-1", name: "Dos Tacos", quantity: 1, unitPrice: Decimal(string: "18.00")!, assignedUserIds: ["owner-2"]),
                SplitSessionItem(id: "item-2", name: "Margarita", quantity: 1, unitPrice: Decimal(string: "12.75")!, assignedUserIds: ["friend-1"])
            ],
            totals: .init(subtotal: Decimal(string: "30.75")!, tax: Decimal(string: "2.96")!, tip: Decimal(string: "5.00")!, total: Decimal(string: "38.71")!)
        )

        let encoded = FirestoreSplitSessionMapper.encodeSession(session)
        let decoded = try XCTUnwrap(FirestoreSplitSessionMapper.decodeSession(documentID: "session-3", data: encoded))

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.ownerUserId, session.ownerUserId)
        XCTAssertEqual(decoded.inviteCode, session.inviteCode)
        XCTAssertEqual(decoded.readyUserIds.sorted(), session.readyUserIds.sorted())
        XCTAssertEqual(decoded.members.count, 2)
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertEqual(decoded.totals.total, session.totals.total)
    }

    func testFirestoreSplitSessionMapperDecodeFiltersReadyUsersToMembers() throws {
        let payload: [String: Any] = [
            "ownerUserId": "owner-3",
            "sourceReceiptId": "receipt-3",
            "merchantName": "Target",
            "createdAt": Timestamp(date: .now),
            "updatedAt": Timestamp(date: .now),
            "status": "draft",
            "readyUserIds": ["owner-3", "ghost-user"],
            "members": [
                ["id": "owner-3", "displayName": "owner@example.com", "role": "owner", "status": "accepted"]
            ],
            "items": [
                ["id": "item-1", "name": "Milk", "quantity": 1, "unitPrice": "3.49", "assignedUserIds": ["owner-3"]]
            ],
            "totals": ["subtotal": "3.49", "tax": "0.30", "tip": "0", "total": "3.79"]
        ]

        let decoded = try XCTUnwrap(FirestoreSplitSessionMapper.decodeSession(documentID: "session-4", data: payload))
        XCTAssertEqual(decoded.readyUserIds, ["owner-3"])
    }
}
