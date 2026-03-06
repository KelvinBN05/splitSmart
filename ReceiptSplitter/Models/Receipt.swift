import Foundation

struct Receipt: Identifiable, Hashable, Codable {
    let id: UUID
    var merchantName: String
    var createdAt: Date
    var participants: [Participant]
    var items: [ReceiptItem]
    var tax: Decimal
    var tip: Decimal
    var sourceOCRJobID: String?

    init(
        id: UUID = UUID(),
        merchantName: String,
        createdAt: Date = .now,
        participants: [Participant],
        items: [ReceiptItem],
        tax: Decimal = 0,
        tip: Decimal = 0,
        sourceOCRJobID: String? = nil
    ) {
        self.id = id
        self.merchantName = merchantName
        self.createdAt = createdAt
        self.participants = participants
        self.items = items
        self.tax = tax
        self.tip = tip
        self.sourceOCRJobID = sourceOCRJobID
    }

    var subtotal: Decimal {
        items.reduce(Decimal.zero) { $0 + $1.subtotal }.roundedToCents()
    }

    var total: Decimal {
        (subtotal + tax + tip).roundedToCents()
    }
}

private extension Decimal {
    func roundedToCents() -> Decimal {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .bankers)
        return rounded
    }
}
