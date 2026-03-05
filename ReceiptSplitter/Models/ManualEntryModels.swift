import Foundation

struct ManualEntryPrefill: Identifiable, Hashable {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var quantity: Int
        var price: String
    }

    let id = UUID()
    var merchantName: String
    var tax: String
    var tip: String
    var items: [Item]
}

struct ManualEntryItemDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var quantity: Int = 1
    var price: String = ""
    var assignedParticipantNames: Set<String> = ["You"]
}

struct ManualSplitResult: Identifiable, Hashable {
    let id = UUID()
    let receipt: Receipt
    let breakdown: [SplitBreakdown]

    static func == (lhs: ManualSplitResult, rhs: ManualSplitResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
