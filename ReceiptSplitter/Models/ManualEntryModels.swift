import Foundation

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
