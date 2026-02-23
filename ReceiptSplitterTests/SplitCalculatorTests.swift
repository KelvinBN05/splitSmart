import XCTest
@testable import ReceiptSplitter

final class SplitCalculatorTests: XCTestCase {
    func testCalculateDistributesItemsTaxAndTipProportionally() {
        let alex = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Alex")
        let sam = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Sam")

        let receipt = Receipt(
            merchantName: "Test Cafe",
            participants: [alex, sam],
            items: [
                ReceiptItem(name: "Pasta", unitPrice: 20, assignedParticipantIDs: [alex.id]),
                ReceiptItem(name: "Salad", unitPrice: 10, assignedParticipantIDs: [sam.id])
            ],
            tax: 3,
            tip: 2
        )

        let result = SplitCalculator.calculate(receipt: receipt)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(totalGrand(from: result), receipt.total)

        let alexBreakdown = try XCTUnwrap(result.first(where: { $0.participant.id == alex.id }))
        let samBreakdown = try XCTUnwrap(result.first(where: { $0.participant.id == sam.id }))

        XCTAssertEqual(alexBreakdown.itemTotal, decimal(20))
        XCTAssertEqual(samBreakdown.itemTotal, decimal(10))

        XCTAssertEqual(alexBreakdown.taxShare, decimal(2))
        XCTAssertEqual(samBreakdown.taxShare, decimal(1))

        XCTAssertEqual(alexBreakdown.tipShare, decimal(1.33))
        XCTAssertEqual(samBreakdown.tipShare, decimal(0.67))
    }

    func testCalculateSplitsUnassignedItemEvenly() {
        let alex = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "Alex")
        let sam = Participant(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, name: "Sam")

        let receipt = Receipt(
            merchantName: "Corner Store",
            participants: [alex, sam],
            items: [
                ReceiptItem(name: "Shared Snack", unitPrice: 9.99)
            ]
        )

        let result = SplitCalculator.calculate(receipt: receipt)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(totalGrand(from: result), receipt.total)

        let alexTotal = result.first(where: { $0.participant.id == alex.id })?.itemTotal
        let samTotal = result.first(where: { $0.participant.id == sam.id })?.itemTotal

        XCTAssertEqual(alexTotal, decimal(5.00))
        XCTAssertEqual(samTotal, decimal(4.99))
    }

    private func totalGrand(from result: [SplitBreakdown]) -> Decimal {
        result.reduce(Decimal.zero) { $0 + $1.grandTotal }
    }

    private func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", value)) ?? .zero
    }
}
