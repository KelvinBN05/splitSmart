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

struct SplitSession: Identifiable, Hashable, Codable {
    let id: String
    let ownerUserId: String
    let sourceReceiptId: String
    let sourceOCRJobID: String?
    var merchantName: String
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var members: [SplitSessionMember]
    var items: [SplitSessionItem]
    var totals: SplitSessionTotals
}

struct SplitSessionMember: Identifiable, Hashable, Codable {
    let id: String
    var displayName: String
    var role: String
    var status: String
}

struct SplitSessionItem: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var quantity: Int
    var unitPrice: Decimal
    var assignedUserIds: [String]
}

struct SplitSessionTotals: Hashable, Codable {
    var subtotal: Decimal
    var tax: Decimal
    var tip: Decimal
    var total: Decimal
}

private extension Decimal {
    func roundedToCents() -> Decimal {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .bankers)
        return rounded
    }
}
