import Foundation

struct SplitBreakdown: Identifiable, Equatable {
    let participant: Participant
    let itemTotal: Decimal
    let taxShare: Decimal
    let tipShare: Decimal

    var id: UUID { participant.id }

    var grandTotal: Decimal {
        (itemTotal + taxShare + tipShare).roundedToCents()
    }
}

enum SplitCalculator {
    static func calculate(receipt: Receipt) -> [SplitBreakdown] {
        guard !receipt.participants.isEmpty else { return [] }

        var itemTotalsByParticipant: [UUID: Decimal] = [:]
        for participant in receipt.participants {
            itemTotalsByParticipant[participant.id] = .zero
        }

        for item in receipt.items {
            let assigned = item.assignedParticipantIDs.intersection(Set(receipt.participants.map(\.id)))
            let consumers = assigned.isEmpty ? Set(receipt.participants.map(\.id)) : assigned
            guard !consumers.isEmpty else { continue }

            let splitAmount = (item.subtotal / Decimal(consumers.count)).roundedToCents()
            let ids = Array(consumers)

            for index in ids.indices {
                let participantID = ids[index]
                let amount: Decimal
                if index == ids.count - 1 {
                    let alreadyAllocated = splitAmount * Decimal(ids.count - 1)
                    amount = (item.subtotal - alreadyAllocated).roundedToCents()
                } else {
                    amount = splitAmount
                }

                itemTotalsByParticipant[participantID, default: .zero] += amount
            }
        }

        let weights = receipt.participants.reduce(into: [UUID: Decimal]()) { result, participant in
            result[participant.id] = itemTotalsByParticipant[participant.id, default: .zero]
        }

        let taxByParticipant = allocateProportionally(amount: receipt.tax, by: weights)
        let tipByParticipant = allocateProportionally(amount: receipt.tip, by: weights)

        return receipt.participants.map { participant in
            SplitBreakdown(
                participant: participant,
                itemTotal: itemTotalsByParticipant[participant.id, default: .zero].roundedToCents(),
                taxShare: taxByParticipant[participant.id, default: .zero].roundedToCents(),
                tipShare: tipByParticipant[participant.id, default: .zero].roundedToCents()
            )
        }
    }

    private static func allocateProportionally(amount: Decimal, by weights: [UUID: Decimal]) -> [UUID: Decimal] {
        let orderedIDs = weights.keys.sorted { $0.uuidString < $1.uuidString }
        guard !orderedIDs.isEmpty else { return [:] }

        let totalWeight = weights.values.reduce(Decimal.zero, +)
        let normalizedWeights: [UUID: Decimal]

        if totalWeight == .zero {
            let equalWeight = Decimal(1)
            normalizedWeights = orderedIDs.reduce(into: [UUID: Decimal]()) { result, id in
                result[id] = equalWeight
            }
        } else {
            normalizedWeights = weights
        }

        let normalizedTotal = normalizedWeights.values.reduce(Decimal.zero, +)
        var result: [UUID: Decimal] = [:]
        var allocated: Decimal = .zero

        for index in orderedIDs.indices {
            let id = orderedIDs[index]
            guard let weight = normalizedWeights[id] else { continue }

            if index == orderedIDs.count - 1 {
                result[id] = (amount - allocated).roundedToCents()
            } else {
                let ratio = weight / normalizedTotal
                let share = (amount * ratio).roundedToCents()
                result[id] = share
                allocated += share
            }
        }

        return result
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
