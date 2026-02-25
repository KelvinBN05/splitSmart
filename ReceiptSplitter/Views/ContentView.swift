import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var receipts = DemoData.receipts

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(receipts: receipts) { newReceipt in
                    receipts.insert(newReceipt, at: 0)
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                HistoryView(receipts: receipts)
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                ProfileView(participant: DemoData.profile)
            }
            .tabItem {
                Label("Profile", systemImage: "person")
            }
        }
        .tint(Color(red: 0.04, green: 0.45, blue: 0.95))
    }
}

private struct HomeView: View {
    let receipts: [Receipt]
    let onReceiptCreated: (Receipt) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                scanCard
                quickActions
                recentActivity
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(AppColors.groupedBackground)
        .navigationTitle("SplitSmart")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("SplitSmart")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.22))
                Text(Formatters.fullDate.string(from: Date()))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(DemoData.profile.initials)
                .font(.headline.weight(.bold))
                .frame(width: 56, height: 56)
                .background(Color.blue.opacity(0.15))
                .clipShape(Circle())
        }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "camera")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.2))
                .clipShape(Circle())

            Text("Scan Receipt")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Start splitting")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.48, blue: 0.95), Color(red: 0.08, green: 0.41, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .blue.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            SmallActionCard(title: "Upload Photo", systemImage: "photo")
            NavigationLink {
                ManualEntryView(onReceiptCreated: onReceiptCreated)
            } label: {
                SmallActionCard(title: "Manual Entry", systemImage: "plus")
            }
            .buttonStyle(.plain)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Spacer()
                Text("See All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            ForEach(receipts.prefix(2)) { receipt in
                ActivityRow(receipt: receipt)
            }
        }
    }
}

private struct SmallActionCard: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 50, height: 50)
                .background(Color.blue.opacity(0.12))
                .clipShape(Circle())
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

private struct ActivityRow: View {
    let receipt: Receipt

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.gray)
                .frame(width: 52, height: 52)
                .background(AppColors.secondaryBackground)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.merchantName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Text(Formatters.shortDate.string(from: receipt.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.currencyString(from: receipt.total))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Text("Split complete")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

private struct HistoryView: View {
    let receipts: [Receipt]

    var body: some View {
        List(receipts) { receipt in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.merchantName)
                    Text(Formatters.numericDate.string(from: receipt.createdAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.currencyString(from: receipt.total))
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("History")
    }
}

private struct ProfileView: View {
    let participant: Participant

    var body: some View {
        VStack(spacing: 16) {
            Text(participant.initials)
                .font(.system(size: 40, weight: .bold))
                .frame(width: 88, height: 88)
                .background(Color.blue.opacity(0.16))
                .clipShape(Circle())
            Text(participant.name)
                .font(.title2.weight(.bold))
            Text("Split smarter with friends.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.groupedBackground)
        .navigationTitle("Profile")
    }
}

private struct ManualEntryView: View {
    let onReceiptCreated: (Receipt) -> Void

    @State private var merchantName = ""
    @State private var participantNames = "You"
    @State private var tax = ""
    @State private var tip = ""
    @State private var itemDrafts: [ManualEntryItemDraft] = [ManualEntryItemDraft()]
    @State private var splitResult: ManualSplitResult?
    @State private var submitErrorMessage: String?
    @State private var isSubmitting = false

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
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deleteItems)

                Button {
                    itemDrafts.append(ManualEntryItemDraft())
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
            SplitResultsView(result: result)
        }
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

    private func deleteItems(at offsets: IndexSet) {
        itemDrafts.remove(atOffsets: offsets)
        if itemDrafts.isEmpty {
            itemDrafts = [ManualEntryItemDraft()]
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
                ManualEntryMapper.ItemInput(name: $0.name, quantity: $0.quantity, price: $0.price)
            }
        )

        let participants = participantNames
            .split(separator: ",")
            .map { String($0) }

        let receipt: Receipt
        do {
            receipt = try ManualEntryMapper.makeReceipt(input: input, participantNames: participants)
        } catch let error as ManualEntryMapper.MapperError {
            submitErrorMessage = mapperErrorText(error)
            return
        } catch {
            submitErrorMessage = "Unable to calculate split. Please review your inputs."
            return
        }

        let breakdown = SplitCalculator.calculate(receipt: receipt)
        splitResult = ManualSplitResult(receipt: receipt, breakdown: breakdown)
        onReceiptCreated(receipt)
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

private struct ManualEntryItemDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var quantity: Int = 1
    var price: String = ""
}

private struct ManualSplitResult: Identifiable, Hashable {
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

private struct SplitResultsView: View {
    let result: ManualSplitResult

    var body: some View {
        List {
            Section("Receipt Summary") {
                LabeledContent("Merchant", value: result.receipt.merchantName)
                LabeledContent("Subtotal", value: Formatters.currencyString(from: result.receipt.subtotal))
                LabeledContent("Tax", value: Formatters.currencyString(from: result.receipt.tax))
                LabeledContent("Tip", value: Formatters.currencyString(from: result.receipt.tip))
                LabeledContent("Total", value: Formatters.currencyString(from: result.receipt.total))
            }

            Section("Per Person Split") {
                ForEach(result.breakdown) { person in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.participant.name)
                            .font(.headline)
                        Text("Items: \(Formatters.currencyString(from: person.itemTotal))")
                        Text("Tax: \(Formatters.currencyString(from: person.taxShare))")
                        Text("Tip: \(Formatters.currencyString(from: person.tipShare))")
                        Text("Grand Total: \(Formatters.currencyString(from: person.grandTotal))")
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Split Result")
    }
}

private enum Formatters {
    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let numericDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale.current
        return formatter
    }()

    static func currencyString(from amount: Decimal) -> String {
        currency.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }
}

private enum AppColors {
    static var groupedBackground: Color {
#if os(iOS)
        return Color(UIColor.systemGroupedBackground)
#elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
#else
        return Color(.systemGray6)
#endif
    }

    static var secondaryBackground: Color {
#if os(iOS)
        return Color(UIColor.secondarySystemBackground)
#elseif os(macOS)
        return Color(NSColor.controlBackgroundColor)
#else
        return Color(.systemGray5)
#endif
    }
}

private enum DemoData {
    static let profile = Participant(name: "Jordan Davis")

    static let receipts: [Receipt] = {
        let joe = Participant(name: "Joe")
        let maya = Participant(name: "Maya")

        let first = Receipt(
            merchantName: "Joe's Pizza",
            createdAt: Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now,
            participants: [joe, maya],
            items: [
                ReceiptItem(name: "Large Pizza", unitPrice: 24, assignedParticipantIDs: [joe.id, maya.id]),
                ReceiptItem(name: "Garlic Knots", unitPrice: 8, assignedParticipantIDs: [maya.id]),
                ReceiptItem(name: "Soda", quantity: 2, unitPrice: 4, assignedParticipantIDs: [joe.id, maya.id])
            ],
            tax: 3.25,
            tip: 6.25
        )

        let second = Receipt(
            merchantName: "Starbucks",
            createdAt: Calendar.current.date(byAdding: .day, value: -5, to: .now) ?? .now,
            participants: [profile],
            items: [
                ReceiptItem(name: "Latte", unitPrice: 6.40, assignedParticipantIDs: [profile.id]),
                ReceiptItem(name: "Sandwich", unitPrice: 5.00, assignedParticipantIDs: [profile.id])
            ],
            tax: 1.00
        )

        return [first, second]
    }()
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
