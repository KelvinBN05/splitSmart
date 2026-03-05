import SwiftUI

struct ManualEntryView: View {
    let onReceiptSaved: (Receipt) -> Void

    @State private var merchantName: String
    @State private var participantNames = "You"
    @State private var tax: String
    @State private var tip: String
    @State private var itemDrafts: [ManualEntryItemDraft]
    @State private var splitResult: ManualSplitResult?
    @State private var submitErrorMessage: String?
    @State private var isSubmitting = false

    init(prefill: ManualEntryPrefill? = nil, onReceiptSaved: @escaping (Receipt) -> Void) {
        self.onReceiptSaved = onReceiptSaved
        _merchantName = State(initialValue: prefill?.merchantName ?? "")
        _tax = State(initialValue: prefill?.tax ?? "")
        _tip = State(initialValue: prefill?.tip ?? "")

        let mappedItems = (prefill?.items ?? []).map { item in
            ManualEntryItemDraft(
                name: item.name,
                quantity: item.quantity,
                price: item.price,
                assignedParticipantNames: ["You"]
            )
        }
        _itemDrafts = State(initialValue: mappedItems.isEmpty ? [ManualEntryItemDraft()] : mappedItems)
    }

    var body: some View {
        Form {
            Section("Receipt Details") {
                TextField("Merchant Name", text: $merchantName)
                TextField("Participants (comma separated)", text: $participantNames)
                TextField("Tax", text: $tax)
                TextField("Tip", text: $tip)

                if !isTaxValid {
                    Text("Tax must be a valid number.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if !isTipValid {
                    Text("Tip must be a valid number.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let submitErrorMessage {
                    Text(submitErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Items") {
                ForEach($itemDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Item name", text: $draft.name)

                        HStack {
                            Stepper("Qty: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                            TextField("Price", text: $draft.price)
                                .multilineTextAlignment(.trailing)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(parsedParticipants, id: \.self) { participant in
                                    Button {
                                        toggleAssignment(for: participant, draft: $draft)
                                    } label: {
                                        Text(participant)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(draft.assignedParticipantNames.contains(participant) ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deleteItems)

                Button {
                    var newDraft = ManualEntryItemDraft()
                    newDraft.assignedParticipantNames = Set(defaultParticipantAssignment)
                    itemDrafts.append(newDraft)
                } label: {
                    Label("Add Item", systemImage: "plus.circle")
                }

                if !hasAtLeastOneValidItem {
                    Text("Add at least one item with a name and numeric price.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Actions") {
                Button("Calculate Split") {
                    submitManualSplit()
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .navigationTitle("Manual Entry")
        .navigationDestination(item: $splitResult) { result in
            SplitResultsView(result: result) { savedReceipt in
                onReceiptSaved(savedReceipt)
            }
        }
    }

    private var parsedParticipants: [String] {
        let values = participantNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if values.isEmpty { return ["You"] }

        var unique: [String] = []
        for name in values where !unique.contains(name) {
            unique.append(name)
        }
        return unique
    }

    private var defaultParticipantAssignment: [String] {
        [parsedParticipants.first ?? "You"]
    }

    private var isMerchantValid: Bool {
        !merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isTaxValid: Bool {
        ManualEntryMapper.parseDecimal(tax) != nil
    }

    private var isTipValid: Bool {
        ManualEntryMapper.parseDecimal(tip) != nil
    }

    private var hasAtLeastOneValidItem: Bool {
        itemDrafts.contains { draft in
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ManualEntryMapper.parseDecimal(draft.price) != nil
        }
    }

    private var canSubmit: Bool {
        isMerchantValid && isTaxValid && isTipValid && hasAtLeastOneValidItem
    }

    private func toggleAssignment(for participant: String, draft: Binding<ManualEntryItemDraft>) {
        if draft.wrappedValue.assignedParticipantNames.contains(participant) {
            draft.wrappedValue.assignedParticipantNames.remove(participant)
            if draft.wrappedValue.assignedParticipantNames.isEmpty {
                draft.wrappedValue.assignedParticipantNames = Set(defaultParticipantAssignment)
            }
        } else {
            draft.wrappedValue.assignedParticipantNames.insert(participant)
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        itemDrafts.remove(atOffsets: offsets)
        if itemDrafts.isEmpty {
            var draft = ManualEntryItemDraft()
            draft.assignedParticipantNames = Set(defaultParticipantAssignment)
            itemDrafts = [draft]
        }
    }

    private func submitManualSplit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        submitErrorMessage = nil

        let input = ManualEntryMapper.Input(
            merchantName: merchantName,
            tax: tax,
            tip: tip,
            items: itemDrafts.map {
                ManualEntryMapper.ItemInput(
                    name: $0.name,
                    quantity: $0.quantity,
                    price: $0.price,
                    assignedParticipantNames: Array($0.assignedParticipantNames)
                )
            }
        )

        let receipt: Receipt
        do {
            receipt = try ManualEntryMapper.makeReceipt(input: input, participantNames: parsedParticipants)
        } catch let error as ManualEntryMapper.MapperError {
            submitErrorMessage = mapperErrorText(error)
            return
        } catch {
            submitErrorMessage = "Unable to calculate split. Please review your inputs."
            return
        }

        let breakdown = SplitCalculator.calculate(receipt: receipt)
        splitResult = ManualSplitResult(receipt: receipt, breakdown: breakdown)
    }

    private func mapperErrorText(_ error: ManualEntryMapper.MapperError) -> String {
        switch error {
        case .emptyMerchant:
            return "Merchant name is required."
        case .invalidTax:
            return "Tax must be a valid number."
        case .invalidTip:
            return "Tip must be a valid number."
        case .noValidItems:
            return "Add at least one valid item."
        }
    }
}

private struct SplitResultsView: View {
    let result: ManualSplitResult
    let onSave: (Receipt) -> Void

    @State private var didSave = false

    var body: some View {
        List {
            Section("Receipt Summary") {
                LabeledContent("Merchant", value: result.receipt.merchantName)
                LabeledContent("Subtotal", value: currencyString(result.receipt.subtotal))
                LabeledContent("Tax", value: currencyString(result.receipt.tax))
                LabeledContent("Tip", value: currencyString(result.receipt.tip))
                LabeledContent("Total", value: currencyString(result.receipt.total))
            }

            Section("Per Person Split") {
                ForEach(result.breakdown) { person in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.participant.name)
                            .font(.headline)
                        Text("Items: \(currencyString(person.itemTotal))")
                        Text("Tax: \(currencyString(person.taxShare))")
                        Text("Tip: \(currencyString(person.tipShare))")
                        Text("Grand Total: \(currencyString(person.grandTotal))")
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Actions") {
                Button(didSave ? "Saved to History" : "Save to History") {
                    guard !didSave else { return }
                    onSave(result.receipt)
                    didSave = true
                }
                .disabled(didSave)
            }
        }
        .navigationTitle("Split Result")
    }

    private func currencyString(_ amount: Decimal) -> String {
        ManualEntryFormatters.currency.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }
}

private enum ManualEntryFormatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale.current
        return formatter
    }()
}
