import SwiftUI
import FirebaseFirestore
#if os(iOS)
import UIKit
import PhotosUI
import Vision
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    let currentUser: AppUser
    let receiptRepository: ReceiptRepository

    @State private var receipts: [Receipt] = []
    @State private var isLoadingReceipts = false
    @State private var loadErrorMessage: String?

    init(currentUser: AppUser, receiptRepository: ReceiptRepository = FirestoreReceiptRepository()) {
        self.currentUser = currentUser
        self.receiptRepository = receiptRepository
    }

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(receipts: receipts) { newReceipt in
                    receipts.insert(newReceipt, at: 0)
                    Task {
                        do {
                            try await receiptRepository.saveReceipt(newReceipt, ownerUserId: currentUser.id)
                        } catch {
                            loadErrorMessage = "Saved locally, but failed to sync to cloud."
                        }
                    }
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
        .task {
            await loadReceipts()
        }
        .alert("Sync Error", isPresented: Binding(
            get: { loadErrorMessage != nil },
            set: { if !$0 { loadErrorMessage = nil } }
        )) {
            Button("Retry") {
                Task {
                    await loadReceipts()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadErrorMessage ?? "Unknown error")
        }
    }

    private func loadReceipts() async {
        guard !isLoadingReceipts else { return }
        isLoadingReceipts = true
        defer { isLoadingReceipts = false }

        do {
            receipts = try await receiptRepository.fetchReceipts(ownerUserId: currentUser.id)
        } catch {
            loadErrorMessage = readableCloudErrorMessage(from: error)
        }
    }

    private func readableCloudErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain {
            switch nsError.code {
            case 7: // permissionDenied
                return "Permission denied. Check Firestore rules and sign-in state."
            case 14, 4: // unavailable, deadlineExceeded
                return "Cloud service unavailable. Check your connection and retry."
            default:
                return "Cloud sync failed. Please try again."
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return "Network error. Check your connection and try again."
        }
        return "Cloud sync failed. Please try again."
    }
}

private struct HomeView: View {
    let receipts: [Receipt]
    let onReceiptSaved: (Receipt) -> Void
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif
    @State private var isProcessingPhoto = false
    @State private var photoProcessingError: String?
    @State private var parsedPrefill: ManualEntryPrefill?

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
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                await processPhotoSelection(item)
            }
        }
#endif
        .navigationDestination(item: $parsedPrefill) { prefill in
            ManualEntryView(prefill: prefill, onReceiptSaved: onReceiptSaved)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
#if os(iOS)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    SmallActionCard(
                        title: isProcessingPhoto ? "Reading Receipt..." : "Upload Photo",
                        systemImage: "photo"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessingPhoto)
#else
                SmallActionCard(title: "Upload Photo", systemImage: "photo")
#endif

                NavigationLink {
                    ManualEntryView(onReceiptSaved: onReceiptSaved)
                } label: {
                    SmallActionCard(title: "Manual Entry", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            if let photoProcessingError {
                Text(photoProcessingError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

#if os(iOS)
    private func processPhotoSelection(_ item: PhotosPickerItem) async {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        photoProcessingError = nil
        defer { isProcessingPhoto = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoProcessingError = "Unable to read selected photo."
                return
            }
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                photoProcessingError = "Could not process that image format."
                return
            }

            let text = try await ReceiptOCRService.extractText(from: cgImage)
            let prefill = ReceiptOCRParser.prefill(fromRecognizedText: text)
            parsedPrefill = prefill
            selectedPhotoItem = nil
        } catch {
            photoProcessingError = "OCR failed. You can still use Manual Entry."
        }
    }
#endif

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

            if receipts.isEmpty {
                EmptyActivityCard()
            } else {
                ForEach(receipts.prefix(2)) { receipt in
                    ActivityRow(receipt: receipt)
                }
            }
        }
    }
}

#if os(iOS)
private enum ReceiptOCRService {
    static func extractText(from cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let lines = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: lines.joined(separator: "\n"))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif

private enum ReceiptOCRParser {
    private static let ignoredLineTokens = [
        "subtotal",
        "total",
        "tax",
        "tip",
        "gratuity",
        "balance",
        "amount due"
    ]

    static func prefill(fromRecognizedText text: String) -> ManualEntryPrefill {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let merchant = detectMerchantName(lines: lines)
        let tax = detectAmount(forKeywords: ["tax"], lines: lines)
        let tip = detectAmount(forKeywords: ["tip", "gratuity"], lines: lines)
        let items = detectItems(lines: lines)

        return ManualEntryPrefill(
            merchantName: merchant,
            tax: tax,
            tip: tip,
            items: items
        )
    }

    private static func detectMerchantName(lines: [String]) -> String {
        for line in lines.prefix(5) {
            let lower = line.lowercased()
            if lower.rangeOfCharacter(from: .letters) == nil { continue }
            if ignoredLineTokens.contains(where: { lower.contains($0) }) { continue }
            return line
        }
        return ""
    }

    private static func detectAmount(forKeywords keywords: [String], lines: [String]) -> String {
        for line in lines {
            let lower = line.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = extractAmount(from: line) {
                return amount
            }
        }
        return ""
    }

    private static func detectItems(lines: [String]) -> [ManualEntryPrefill.Item] {
        var detected: [ManualEntryPrefill.Item] = []

        for line in lines {
            guard let amount = extractTrailingAmount(from: line) else { continue }
            let lower = line.lowercased()
            if ignoredLineTokens.contains(where: { lower.contains($0) }) { continue }

            let namePortion = line.replacingOccurrences(of: amount, with: "")
            let cleanedName = namePortion
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard cleanedName.count >= 2 else { continue }

            detected.append(
                ManualEntryPrefill.Item(
                    name: cleanedName,
                    quantity: 1,
                    price: amount
                )
            )
        }

        if detected.isEmpty {
            return []
        }

        return Array(detected.prefix(12))
    }

    private static func extractAmount(from line: String) -> String? {
        let pattern = #"([0-9]+(?:\.[0-9]{1,2})?)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.matches(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ).last,
            let amountRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[amountRange])
    }

    private static func extractTrailingAmount(from line: String) -> String? {
        let pattern = #"([0-9]+(?:\.[0-9]{1,2})?)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ),
            let amountRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[amountRange])
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
        Group {
            if receipts.isEmpty {
                ContentUnavailableView(
                    "No Receipts Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Add a receipt from Home to see your history.")
                )
            } else {
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
            }
        }
        .navigationTitle("History")
    }
}

private struct EmptyActivityCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
            Text("Create your first receipt from Manual Entry.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
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
        ContentView(currentUser: AppUser(id: "preview-user", email: "preview@example.com"))
    }
}
