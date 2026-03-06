import XCTest
@testable import ReceiptSplitter

final class SplitSessionTests: XCTestCase {
    func testAccessCanReadForOwnerAndMembersOnly() {
        let session = makeSession(
            ownerUserId: "owner-1",
            members: [
                SplitSessionMember(id: "owner-1", displayName: "Owner", role: "owner", status: "accepted"),
                SplitSessionMember(id: "member-1", displayName: "Member", role: "member", status: "accepted")
            ],
            readyUserIds: []
        )

        XCTAssertTrue(SplitSessionAccess.canRead(session, userId: "owner-1"))
        XCTAssertTrue(SplitSessionAccess.canRead(session, userId: "member-1"))
        XCTAssertFalse(SplitSessionAccess.canRead(session, userId: "outsider-1"))
    }

    func testAccessFinalizeRequiresOwnerAndAllMembersReady() {
        let baseMembers = [
            SplitSessionMember(id: "owner-1", displayName: "Owner", role: "owner", status: "accepted"),
            SplitSessionMember(id: "member-1", displayName: "Member", role: "member", status: "accepted")
        ]

        let allReady = makeSession(ownerUserId: "owner-1", members: baseMembers, readyUserIds: ["owner-1", "member-1"])
        XCTAssertTrue(SplitSessionAccess.canFinalize(allReady, userId: "owner-1"))
        XCTAssertFalse(SplitSessionAccess.canFinalize(allReady, userId: "member-1"))

        let missingReady = makeSession(ownerUserId: "owner-1", members: baseMembers, readyUserIds: ["owner-1"])
        XCTAssertFalse(SplitSessionAccess.canFinalize(missingReady, userId: "owner-1"))
    }

    func testMemberTotalsSplitSharedItemsAndAllocateTaxTip() {
        let session = SplitSession(
            id: "session-1",
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
            members: [
                SplitSessionMember(id: "owner-1", displayName: "Owner", role: "owner", status: "accepted"),
                SplitSessionMember(id: "member-1", displayName: "Member", role: "member", status: "accepted")
            ],
            items: [
                SplitSessionItem(id: "item-1", name: "Shared Nachos", quantity: 1, unitPrice: 12, assignedUserIds: ["owner-1", "member-1"]),
                SplitSessionItem(id: "item-2", name: "Drink", quantity: 1, unitPrice: 6, assignedUserIds: ["owner-1"])
            ],
            totals: SplitSessionTotals(subtotal: 18, tax: 1.8, tip: 3.6, total: 23.4)
        )

        let totals = SplitSessionCalculator.memberTotals(for: session)
        XCTAssertEqual(totals.count, 2)

        let owner = try? XCTUnwrap(totals.first(where: { $0.userId == "owner-1" }))
        let member = try? XCTUnwrap(totals.first(where: { $0.userId == "member-1" }))
        XCTAssertNotNil(owner)
        XCTAssertNotNil(member)

        if let owner {
            XCTAssertEqual(owner.itemTotal, decimal("12"))
            XCTAssertEqual(owner.taxShare, decimal("1.2"))
            XCTAssertEqual(owner.tipShare, decimal("2.4"))
            XCTAssertEqual(owner.grandTotal, decimal("15.6"))
        }

        if let member {
            XCTAssertEqual(member.itemTotal, decimal("6"))
            XCTAssertEqual(member.taxShare, decimal("0.6"))
            XCTAssertEqual(member.tipShare, decimal("1.2"))
            XCTAssertEqual(member.grandTotal, decimal("7.8"))
        }
    }

    private func makeSession(
        ownerUserId: String,
        members: [SplitSessionMember],
        readyUserIds: [String]
    ) -> SplitSession {
        SplitSession(
            id: "session-x",
            ownerUserId: ownerUserId,
            sourceReceiptId: "receipt-x",
            sourceOCRJobID: nil,
            merchantName: "Store",
            createdAt: .now,
            updatedAt: .now,
            status: "draft",
            inviteCode: nil,
            readyUserIds: readyUserIds,
            finalizedAt: nil,
            members: members,
            items: [],
            totals: .init(subtotal: 0, tax: 0, tip: 0, total: 0)
        )
    }

    private func decimal(_ value: String) -> Decimal {
        Decimal(string: value) ?? .zero
    }
}
