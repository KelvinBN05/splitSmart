import Foundation

struct ReceiptItem: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var quantity: Int
    var unitPrice: Decimal
    var assignedParticipantIDs: Set<UUID>

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int = 1,
        unitPrice: Decimal,
        assignedParticipantIDs: Set<UUID> = []
    ) {
        self.id = id
        self.name = name
        self.quantity = max(quantity, 1)
        self.unitPrice = unitPrice
        self.assignedParticipantIDs = assignedParticipantIDs
    }

    var subtotal: Decimal {
        (unitPrice * Decimal(quantity)).roundedToCents()
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
