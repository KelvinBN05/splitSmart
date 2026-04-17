import SwiftUI

struct ManualEntryView: View {
    let onReceiptSaved: (Receipt) -> Void
    let friendSuggestions: [String]

    @State private var merchantName: String
    @State private var participantNames = "You"
    @State private var tax: String
    @State private var tip: String
    @State private var sourceOCRJobID: String?
    @State private var itemDrafts: [ManualEntryItemDraft]
    @State private var splitResult: ManualSplitResult?
    @State private var submitErrorMessage: String?
    @State private var isSubmitting = false

    init(
        prefill: ManualEntryPrefill? = nil,
        friendSuggestions: [String] = [],
        onReceiptSaved: @escaping (Receipt) -> Void
    ) {
        self.onReceiptSaved = onReceiptSaved
        self.friendSuggestions = friendSuggestions
        _merchantName = State(initialValue: prefill?.merchantName ?? "")
        _tax = State(initialValue: prefill?.tax ?? "")
        _tip = State(initialValue: prefill?.tip ?? "")
        _sourceOCRJobID = State(initialValue: prefill?.sourceOCRJobID)

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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppSectionHeader(
                        "Manual Entry",
                        eyebrow: "Build Split",
                        detail: "Set the receipt details, assign people, then calculate the split."
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Receipt Details")
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)

                        Text("Add the merchant, who joined the bill, and the extra charges before assigning items.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.muted)

                        TextField("Merchant Name", text: $merchantName)
                            .appInputField()

                        TextField("Participants (comma separated)", text: $participantNames)
                            .appInputField()
#if os(iOS)
                            .textInputAutocapitalization(.words)
#endif

                        if !friendSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(friendSuggestions, id: \.self) { friendName in
                                        let isSelected = parsedParticipants.contains(friendName)
                                        Button {
                                            addParticipantIfNeeded(friendName)
                                        } label: {
                                            Label(friendName, systemImage: isSelected ? "checkmark.circle.fill" : "plus.circle")
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(isSelected ? Color.green.opacity(0.18) : AppTheme.goldSoft)
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            TextField("Tax", text: $tax)
                                .appInputField()
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                            TextField("Tip", text: $tip)
                                .appInputField()
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                        }

                        if !isTaxValid {
                            validationMessage("Tax must be a valid number.")
                        }
                        if !isTipValid {
                            validationMessage("Tip must be a valid number.")
                        }
                        if let submitErrorMessage {
                            validationMessage(submitErrorMessage)
                        }
                    }
                    .appCard(cornerRadius: 24, padded: true)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Items")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            Button {
                                var newDraft = ManualEntryItemDraft()
                                newDraft.assignedParticipantNames = Set(defaultParticipantAssignment)
                                itemDrafts.append(newDraft)
                            } label: {
                                Label("Add Item", systemImage: "plus.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.gold)
                        }

                        Text("Assign each item to one or more people. Totals update after calculation.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.muted)

                        ForEach($itemDrafts) { $draft in
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Item name", text: $draft.name)
                                    .appInputField()

                                HStack(spacing: 12) {
                                    Stepper("Qty: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    TextField("Price", text: $draft.price)
                                        .multilineTextAlignment(.trailing)
                                        .appInputField()
#if os(iOS)
                                        .keyboardType(.decimalPad)
#endif
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
                                                    .background(draft.assignedParticipantNames.contains(participant) ? AppTheme.goldSoft : AppColors.secondaryBackground)
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }

                        if !hasAtLeastOneValidItem {
                            validationMessage("Add at least one item with a name and numeric price.")
                        }
                    }
                    .appCard(cornerRadius: 24, padded: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 120)
            }
            .background(AppTheme.pageGradient.ignoresSafeArea())

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ready to calculate?")
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        Text("Review the people and item prices before continuing.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.muted)
                    }
                    Spacer()
                }

                Button("Calculate Split") {
                    submitManualSplit()
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmit && !isSubmitting ? AppTheme.gold : AppTheme.line)
                .foregroundStyle(canSubmit && !isSubmitting ? .white : AppTheme.muted)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(!canSubmit || isSubmitting)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Manual Entry")
        .navigationDestination(item: $splitResult) { result in
            SplitResultsView(result: result) { savedReceipt in
                onReceiptSaved(savedReceipt)
            }
        }
    }

    private func validationMessage(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.danger)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.danger)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var parsedParticipants: [String] {
        let values = participantNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if values.isEmpty { return ["You"] }

        var unique: [String] = []
        var seenLowercased: Set<String> = []
        for name in values {
            let lowered = name.lowercased()
            guard !seenLowercased.contains(lowered) else { continue }
            seenLowercased.insert(lowered)
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

    private func addParticipantIfNeeded(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !parsedParticipants.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        let existing = participantNames.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            participantNames = trimmed
        } else {
            participantNames = "\(existing), \(trimmed)"
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

        var receipt: Receipt
        do {
            receipt = try ManualEntryMapper.makeReceipt(input: input, participantNames: parsedParticipants)
            receipt.sourceOCRJobID = sourceOCRJobID
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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppSectionHeader(
                        "Split Result",
                        eyebrow: "Summary",
                        detail: "Review the totals below before saving this receipt to history."
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        Text(result.receipt.merchantName)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)

                        HStack(spacing: 12) {
                            AppMetricPill(label: "Subtotal", value: currencyString(result.receipt.subtotal))
                            AppMetricPill(label: "Total", value: currencyString(result.receipt.total))
                        }

                        HStack(spacing: 18) {
                            resultStat("Tax", value: currencyString(result.receipt.tax))
                            resultStat("Tip", value: currencyString(result.receipt.tip))
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.heroGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Per Person Split")
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)

                        ForEach(result.breakdown) { person in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(person.participant.name)
                                        .font(.headline)
                                        .foregroundStyle(AppTheme.ink)
                                    Spacer()
                                    Text(currencyString(person.grandTotal))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(AppTheme.gold)
                                }

                                HStack(spacing: 18) {
                                    resultStat("Items", value: currencyString(person.itemTotal))
                                    resultStat("Tax", value: currencyString(person.taxShare))
                                    resultStat("Tip", value: currencyString(person.tipShare))
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .appCard(cornerRadius: 24, padded: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
            .background(AppTheme.pageGradient.ignoresSafeArea())

            VStack(spacing: 10) {
                Button(didSave ? "Saved to History" : "Save to History") {
                    guard !didSave else { return }
                    onSave(result.receipt)
                    didSave = true
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(didSave ? AppTheme.success : AppTheme.gold)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(didSave)

                Text(didSave ? "This receipt is now in History." : "Saving also makes the split available from the History tab.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Split Result")
    }

    private func currencyString(_ amount: Decimal) -> String {
        ManualEntryFormatters.currency.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }

    private func resultStat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.ink)
        }
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
