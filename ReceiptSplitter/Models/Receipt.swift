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
    var inviteCode: String?
    var readyUserIds: [String]
    var finalizedAt: Date?
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

struct ReceiptInvite: Identifiable, Hashable {
    let id: String
    let senderId: String
    let senderDisplayName: String
    let senderEmail: String
    let recipientId: String
    let recipientEmail: String
    let status: String
    let receipt: Receipt
    let createdAt: Date?
    let updatedAt: Date?
}

enum SplitSessionAccess {
    static func canRead(_ session: SplitSession, userId: String) -> Bool {
        session.ownerUserId == userId || session.members.contains(where: { $0.id == userId })
    }

    static func canFinalize(_ session: SplitSession, userId: String) -> Bool {
        guard session.ownerUserId == userId else { return false }
        return Set(session.readyUserIds) == Set(session.members.map(\.id))
    }
}

enum SplitSessionCalculator {
    struct MemberTotal: Hashable {
        let userId: String
        let itemTotal: Decimal
        let taxShare: Decimal
        let tipShare: Decimal
        let grandTotal: Decimal
    }

    static func memberTotals(for session: SplitSession) -> [MemberTotal] {
        let memberIDs = session.members.map(\.id)
        guard !memberIDs.isEmpty else { return [] }

        let itemTotalsByUser: [String: Decimal] = memberIDs.reduce(into: [:]) { partial, userId in
            partial[userId] = session.items.reduce(Decimal.zero) { subtotal, item in
                guard item.assignedUserIds.contains(userId), !item.assignedUserIds.isEmpty else { return subtotal }
                let divisor = Decimal(item.assignedUserIds.count)
                return subtotal + ((Decimal(item.quantity) * item.unitPrice) / divisor)
            }
        }

        let subtotal = itemTotalsByUser.values.reduce(Decimal.zero, +)
        let safeSubtotal = subtotal == 0 ? Decimal(1) : subtotal

        return memberIDs.map { userId in
            let itemTotal = itemTotalsByUser[userId] ?? 0
            let taxShare = (session.totals.tax * itemTotal) / safeSubtotal
            let tipShare = (session.totals.tip * itemTotal) / safeSubtotal
            let grand = itemTotal + taxShare + tipShare
            return MemberTotal(
                userId: userId,
                itemTotal: itemTotal,
                taxShare: taxShare,
                tipShare: tipShare,
                grandTotal: grand
            )
        }
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
