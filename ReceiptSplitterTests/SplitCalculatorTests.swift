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

    func testManualEntryMapperBuildsReceiptFromValidInput() throws {
        let input = ManualEntryMapper.Input(
            merchantName: "Cafe Blue",
            tax: "1.25",
            tip: "2.00",
            items: [
                .init(name: "Latte", quantity: 1, price: "5.50"),
                .init(name: "Bagel", quantity: 2, price: "3.00")
            ]
        )

        let receipt = try ManualEntryMapper.makeReceipt(input: input)

        XCTAssertEqual(receipt.merchantName, "Cafe Blue")
        XCTAssertEqual(receipt.tax, decimal(1.25))
        XCTAssertEqual(receipt.tip, decimal(2.00))
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertEqual(receipt.items[1].quantity, 2)
        XCTAssertEqual(receipt.total, decimal(12.75))
    }

    func testManualEntryMapperRejectsInvalidTax() {
        let input = ManualEntryMapper.Input(
            merchantName: "Cafe Blue",
            tax: "abc",
            tip: "1.00",
            items: [.init(name: "Latte", quantity: 1, price: "5.00")]
        )

        XCTAssertThrowsError(try ManualEntryMapper.makeReceipt(input: input)) { error in
            XCTAssertEqual(error as? ManualEntryMapper.MapperError, .invalidTax)
        }
    }

    func testManualEntryMapperRequiresAtLeastOneValidItem() {
        let input = ManualEntryMapper.Input(
            merchantName: "Cafe Blue",
            tax: "",
            tip: "",
            items: [.init(name: "", quantity: 1, price: "")]
        )

        XCTAssertThrowsError(try ManualEntryMapper.makeReceipt(input: input)) { error in
            XCTAssertEqual(error as? ManualEntryMapper.MapperError, .noValidItems)
        }
    }

    private func totalGrand(from result: [SplitBreakdown]) -> Decimal {
        result.reduce(Decimal.zero) { $0 + $1.grandTotal }
    }

    private func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", value)) ?? .zero
    }
}
