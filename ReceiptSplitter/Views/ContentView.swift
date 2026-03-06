import SwiftUI
import FirebaseFirestore
#if os(iOS)
import UIKit
import PhotosUI
import FirebaseStorage
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let currentUser: AppUser
    let receiptRepository: ReceiptRepository
    let userProfileRepository: UserProfileRepository

    @State private var receipts: [Receipt] = []
    @State private var isLoadingReceipts = false
    @State private var loadErrorMessage: String?
    @State private var isAccountSheetPresented = false
    @State private var accountDisplayName = ""
    @State private var isSavingDisplayName = false

    init(
        currentUser: AppUser,
        receiptRepository: ReceiptRepository = FirestoreReceiptRepository(),
        userProfileRepository: UserProfileRepository = FirestoreUserProfileRepository()
    ) {
        self.currentUser = currentUser
        self.receiptRepository = receiptRepository
        self.userProfileRepository = userProfileRepository
    }

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(
                    currentUserID: currentUser.id,
                    receipts: receipts,
                    userInitials: userInitials
                ) {
                    isAccountSheetPresented = true
                } onReceiptSaved: { newReceipt in
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
                HistoryView(currentUserID: currentUser.id, currentUserEmail: currentUser.email ?? "unknown@example.com", receipts: receipts)
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                AccountTabView(
                    displayName: accountDisplayName.isEmpty ? defaultDisplayName : accountDisplayName,
                    email: currentUser.email ?? "unknown@example.com",
                    initials: userInitials
                )
            }
            .tabItem {
                Label("Profile", systemImage: "person")
            }
        }
        .tint(Color(red: 0.04, green: 0.45, blue: 0.95))
        .task {
            await loadReceipts()
        }
        .task {
            await loadAccountProfile()
        }
        .sheet(isPresented: $isAccountSheetPresented) {
            NavigationStack {
                AccountProfileSheet(
                    email: currentUser.email ?? "unknown@example.com",
                    displayName: $accountDisplayName,
                    isSaving: isSavingDisplayName,
                    onSave: {
                        Task { await saveDisplayName() }
                    },
                    onSignOut: {
                        sessionStore.signOut()
                        isAccountSheetPresented = false
                    }
                )
            }
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

    private func loadAccountProfile() async {
        do {
            if let profile = try await userProfileRepository.fetchUserProfile(userID: currentUser.id),
               !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accountDisplayName = profile.displayName
            }
        } catch {
            // Non-blocking: profile data is optional for initial load.
        }
    }

    private func saveDisplayName() async {
        let trimmed = accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSavingDisplayName else { return }

        isSavingDisplayName = true
        defer { isSavingDisplayName = false }

        do {
            try await userProfileRepository.updateDisplayName(userID: currentUser.id, displayName: trimmed)
            accountDisplayName = trimmed
        } catch {
            loadErrorMessage = "Failed to save display name."
        }
    }

    private var userInitials: String {
        let source = accountDisplayName.isEmpty ? defaultDisplayName : accountDisplayName
        return initials(from: source)
    }

    private var defaultDisplayName: String {
        guard let email = currentUser.email, !email.isEmpty else { return "User" }
        return email.components(separatedBy: "@").first ?? "User"
    }

    private func initials(from text: String) -> String {
        let parts = text
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(text.prefix(2)).uppercased()
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
    private enum ScanFlowStage {
        case idle
        case uploading
        case processing
        case review
        case saving
        case saved
        case failed
    }

    let currentUserID: String
    let receipts: [Receipt]
    let userInitials: String
    let onAccountTapped: () -> Void
    let onReceiptSaved: (Receipt) -> Void
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif
    @State private var isProcessingPhoto = false
    @State private var photoProcessingError: String?
    @State private var parsedPrefill: ManualEntryPrefill?
    @State private var reviewPrefill: OCRReviewPrefill?
    @State private var scanFlowStage: ScanFlowStage = .idle
    @State private var scanFlowDetail = "Upload a receipt photo to start."
    @State private var latestOCRJobID: String?

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
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await processPhotoSelection(item)
            }
        }
#endif
        .navigationDestination(item: $parsedPrefill) { prefill in
            ManualEntryView(prefill: prefill) { savedReceipt in
                scanFlowStage = .saved
                scanFlowDetail = "Receipt saved to History."
                onReceiptSaved(savedReceipt)
            }
        }
        .navigationDestination(item: $reviewPrefill) { review in
            OCRReviewView(prefill: review.prefill) { approvedPrefill in
                scanFlowStage = .saving
                scanFlowDetail = "Apply edits and tap Save to History."
                parsedPrefill = approvedPrefill
            }
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

            Button(action: onAccountTapped) {
                Text(userInitials)
                    .font(.headline.weight(.bold))
                    .frame(width: 56, height: 56)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
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
                        title: isBusy ? "Scanning..." : "Upload Photo",
                        systemImage: "photo"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessingPhoto || isBusy)
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

            scanFlowStatusCard
        }
    }

    private var scanFlowStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: scanFlowIconName)
                    .foregroundStyle(scanFlowTint)
                Text(scanFlowTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Spacer()
            }

            Text(scanFlowDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isBusy {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let latestOCRJobID, !latestOCRJobID.isEmpty {
                Text("OCR Job: \(latestOCRJobID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if scanFlowStage == .failed || scanFlowStage == .saved {
                Button("Reset Scan Status") {
                    resetScanStatus()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(scanFlowTint.opacity(0.20), lineWidth: 1)
        )
    }

    private var scanFlowTitle: String {
        switch scanFlowStage {
        case .idle:
            return "Ready to scan"
        case .uploading:
            return "Uploading photo"
        case .processing:
            return "Running OCR"
        case .review:
            return "Review OCR result"
        case .saving:
            return "Ready to save"
        case .saved:
            return "Saved"
        case .failed:
            return "Scan failed"
        }
    }

    private var scanFlowIconName: String {
        switch scanFlowStage {
        case .idle:
            return "camera.viewfinder"
        case .uploading:
            return "arrow.up.circle"
        case .processing:
            return "cpu"
        case .review:
            return "doc.text.magnifyingglass"
        case .saving:
            return "square.and.pencil"
        case .saved:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var scanFlowTint: Color {
        switch scanFlowStage {
        case .saved:
            return .green
        case .failed:
            return .red
        case .idle:
            return .secondary
        default:
            return .blue
        }
    }

    private var isBusy: Bool {
        scanFlowStage == .uploading || scanFlowStage == .processing
    }

    private func resetScanStatus() {
        scanFlowStage = .idle
        scanFlowDetail = "Upload a receipt photo to start."
        photoProcessingError = nil
        latestOCRJobID = nil
    }

#if os(iOS)
    private func processPhotoSelection(_ item: PhotosPickerItem) async {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        photoProcessingError = nil
        scanFlowStage = .uploading
        scanFlowDetail = "Sending receipt image to cloud OCR."
        defer { isProcessingPhoto = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoProcessingError = "Unable to read selected photo."
                scanFlowStage = .failed
                scanFlowDetail = "Could not read selected photo."
                return
            }
            guard UIImage(data: data) != nil else {
                photoProcessingError = "Could not process that image format."
                scanFlowStage = .failed
                scanFlowDetail = "Could not process that image format."
                return
            }

            let prefill = try await DocumentAIOCRJobService.createAndAwaitOCRJob(
                imageData: data,
                ownerUserID: currentUserID,
                onStatusChange: { status in
                switch status {
                case .uploading:
                    scanFlowStage = .uploading
                    scanFlowDetail = "Uploading image to storage."
                case .processing:
                    scanFlowStage = .processing
                    scanFlowDetail = "Waiting for OCR extraction."
                }
            })

            latestOCRJobID = prefill.sourceOCRJobID
            scanFlowStage = .review
            scanFlowDetail = "Review extracted items before saving."
            reviewPrefill = OCRReviewPrefill(prefill: prefill)
            selectedPhotoItem = nil
        } catch {
            photoProcessingError = error.localizedDescription
            scanFlowStage = .failed
            scanFlowDetail = error.localizedDescription
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
private enum DocumentAIOCRJobService {
    private static let db = Firestore.firestore()
    private static let storage = Storage.storage()

    enum OCRPipelineStatus {
        case uploading
        case processing
    }

    enum OCRJobError: LocalizedError {
        case timedOut
        case failed(String)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "OCR timed out. Try again in a moment."
            case .failed(let message):
                return message.isEmpty ? "OCR failed." : message
            case .invalidPayload:
                return "OCR result payload was invalid."
            }
        }
    }

    static func createAndAwaitOCRJob(
        imageData: Data,
        ownerUserID: String,
        onStatusChange: ((OCRPipelineStatus) -> Void)? = nil
    ) async throws -> ManualEntryPrefill {
        let jobID = UUID().uuidString
        let imagePath = "users/\(ownerUserID)/ocrUploads/\(jobID).jpg"
        let jobRef = db.collection("users").document(ownerUserID).collection("ocrJobs").document(jobID)

        onStatusChange?(.uploading)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        _ = try await storage.reference(withPath: imagePath).putDataAsync(imageData, metadata: metadata)

        try await jobRef.setData([
            "status": "pending",
            "ownerUserId": ownerUserID,
            "imagePath": imagePath,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        onStatusChange?(.processing)
        var prefill = try await waitForCompletion(jobRef: jobRef, timeoutSeconds: 60)
        prefill.sourceOCRJobID = jobID
        return prefill
    }

    private static func waitForCompletion(
        jobRef: DocumentReference,
        timeoutSeconds: Double
    ) async throws -> ManualEntryPrefill {
        let start = Date()

        while Date().timeIntervalSince(start) < timeoutSeconds {
            let snapshot = try await jobRef.getDocument()
            let data = snapshot.data() ?? [:]
            let status = (data["status"] as? String ?? "pending").lowercased()

            switch status {
            case "completed":
                guard let result = data["result"] as? [String: Any] else {
                    throw OCRJobError.invalidPayload
                }
                return mapPrefill(from: result)
            case "failed":
                let message = data["errorMessage"] as? String ?? "OCR failed."
                throw OCRJobError.failed(message)
            default:
                try await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        throw OCRJobError.timedOut
    }

    private static func mapPrefill(from result: [String: Any]) -> ManualEntryPrefill {
        let canonicalResult: [String: Any]
        if
            result["merchantName"] == nil,
            let nested = result["items"] as? [String: Any],
            nested["merchantName"] != nil || nested["items"] != nil
        {
            canonicalResult = nested
        } else {
            canonicalResult = result
        }

        let merchantName = (canonicalResult["merchantName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tax = normalizeAmount(canonicalResult["tax"])
        let tip = normalizeAmount(canonicalResult["tip"])

        let itemsRaw = canonicalResult["items"] as? [[String: Any]] ?? []
        let items = itemsRaw.compactMap { raw -> ManualEntryPrefill.Item? in
            let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }

            let quantity = max(1, (raw["quantity"] as? Int) ?? 1)
            let price = normalizeAmount(raw["price"])
            guard !price.isEmpty else { return nil }

            return ManualEntryPrefill.Item(name: name, quantity: quantity, price: price)
        }

        return ManualEntryPrefill(
            merchantName: merchantName,
            tax: tax,
            tip: tip,
            items: items,
            sourceOCRJobID: nil
        )
    }

    private static func normalizeAmount(_ raw: Any?) -> String {
        if let string = raw as? String {
            let cleaned = string
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decimal = Decimal(string: cleaned) else { return "" }
            return NSDecimalNumber(decimal: decimal).stringValue
        }

        if let number = raw as? NSNumber {
            return number.decimalValue.description
        }

        return ""
    }
}
#endif

private struct OCRReviewPrefill: Identifiable, Hashable {
    let id = UUID()
    var prefill: ManualEntryPrefill
}

private struct OCRReviewRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var quantity: Int
    var price: String
    var isDiscount: Bool

    init(item: ManualEntryPrefill.Item) {
        name = item.name
        quantity = item.quantity
        price = item.price
        let lower = item.name.lowercased()
        isDiscount = lower.contains("coupon") || lower.contains("saved") || lower.contains("discount")
    }
}

private struct OCRReviewView: View {
    let prefill: ManualEntryPrefill
    let onContinue: (ManualEntryPrefill) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var merchantName: String
    @State private var tax: String
    @State private var tip: String
    @State private var rows: [OCRReviewRow]

    init(prefill: ManualEntryPrefill, onContinue: @escaping (ManualEntryPrefill) -> Void) {
        self.prefill = prefill
        self.onContinue = onContinue
        _merchantName = State(initialValue: prefill.merchantName)
        _tax = State(initialValue: prefill.tax)
        _tip = State(initialValue: prefill.tip)
        _rows = State(initialValue: prefill.items.map { OCRReviewRow(item: $0) })
    }

    var body: some View {
        List {
            Section("Receipt") {
                TextField("Merchant", text: $merchantName)
                TextField("Tax", text: $tax)
                TextField("Tip", text: $tip)
            }

            Section("Review OCR Items") {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Item name", text: $row.name)
                        HStack(spacing: 12) {
                            Stepper("Qty \(row.quantity)", value: $row.quantity, in: 1...99)
                            TextField("Price", text: $row.price)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("Mark as discount", isOn: $row.isDiscount)
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    rows.remove(atOffsets: offsets)
                }

                Button {
                    rows.append(OCRReviewRow(item: .init(name: "", quantity: 1, price: "")))
                } label: {
                    Label("Add Row", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Review OCR")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    onContinue(makeApprovedPrefill())
                }
                .disabled(validRows.isEmpty)
            }
        }
    }

    private var validRows: [OCRReviewRow] {
        rows.filter {
            !$0.isDiscount &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            Decimal(string: $0.price.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    private func makeApprovedPrefill() -> ManualEntryPrefill {
        let cleanedItems: [ManualEntryPrefill.Item] = validRows.map { row in
            ManualEntryPrefill.Item(
                name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: max(1, row.quantity),
                price: row.price.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return ManualEntryPrefill(
            merchantName: merchantName.trimmingCharacters(in: .whitespacesAndNewlines),
            tax: tax.trimmingCharacters(in: .whitespacesAndNewlines),
            tip: tip.trimmingCharacters(in: .whitespacesAndNewlines),
            items: cleanedItems,
            sourceOCRJobID: prefill.sourceOCRJobID
        )
    }
}

private struct OCRSegment: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

private struct OCRRow: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let segments: [OCRSegment]
    let yCenter: CGFloat
}

private struct OCRScanData: Hashable {
    let rows: [OCRRow]

    var lines: [String] {
        rows.map(\.text)
    }
}

private struct OCRDebugPayload: Identifiable {
    let id = UUID()
    let scan: OCRScanData
    let prefill: ManualEntryPrefill
}

#if os(iOS)
private enum ReceiptOCRService {
    private static let ciContext = CIContext()

    static func extractScan(from cgImage: CGImage) async throws -> OCRScanData {
        let imageForOCR = preprocessForOCR(cgImage) ?? cgImage

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRScanData, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRScanData(rows: []))
                    return
                }

                let fragments: [OCRSegment] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }

                    return OCRSegment(
                        text: text,
                        confidence: candidate.confidence,
                        boundingBox: observation.boundingBox
                    )
                }

                let rows = groupStrictRows(from: fragments)

                continuation.resume(returning: OCRScanData(rows: rows))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.012

            let handler = VNImageRequestHandler(cgImage: imageForOCR, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func preprocessForOCR(_ cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = input
        colorControls.saturation = 0
        colorControls.contrast = 1.45
        colorControls.brightness = 0.03

        guard let colorAdjusted = colorControls.outputImage else { return nil }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = colorAdjusted
        sharpen.sharpness = 0.75

        guard let sharpened = sharpen.outputImage else { return nil }

        return ciContext.createCGImage(sharpened, from: sharpened.extent)
    }

    private static func groupStrictRows(from fragments: [OCRSegment]) -> [OCRRow] {
        guard !fragments.isEmpty else { return [] }

        let sorted = fragments.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        // Tight threshold so only same-row fragments merge.
        // Prevents the earlier over-merge problem.
        let yTolerance: CGFloat = 0.0035

        var buckets: [[OCRSegment]] = []

        for fragment in sorted {
            var assigned = false
            for index in buckets.indices {
                let avgY = buckets[index].map(\.boundingBox.midY).reduce(0, +) / CGFloat(buckets[index].count)
                if abs(avgY - fragment.boundingBox.midY) <= yTolerance {
                    buckets[index].append(fragment)
                    assigned = true
                    break
                }
            }

            if !assigned {
                buckets.append([fragment])
            }
        }

        let rows: [OCRRow] = buckets.map { bucket in
            let segments = bucket.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let text = segments.map(\.text).joined(separator: " ")
            let yCenter = segments.map(\.boundingBox.midY).reduce(0, +) / CGFloat(segments.count)
            return OCRRow(text: text, segments: segments, yCenter: yCenter)
        }

        return rows.sorted { $0.yCenter > $1.yCenter }
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
        "amount due",
        "visa",
        "mastercard",
        "discover",
        "amex",
        "card",
        "payment",
        "cash",
        "change",
        "auth",
        "approval",
        "transaction",
        "invoice",
        "order #",
        "table",
        "server",
        "thank you"
    ]

    static func prefill(from scan: OCRScanData) -> ManualEntryPrefill {
        let lines = scan.lines

        let merchant = detectMerchantName(lines: lines)
        let tax = detectAmount(forKeywords: ["tax"], lines: lines)
        let tip = detectAmount(forKeywords: ["tip", "gratuity"], lines: lines)
        let items = detectItems(rows: scan.rows)

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
            if let amount = extractTrailingAmount(from: line) ?? extractAmount(from: line) {
                return amount
            }
        }
        return ""
    }

    private static func detectItems(rows: [OCRRow]) -> [ManualEntryPrefill.Item] {
        let boundaryItems = detectItems(rows: rows, useSubtotalBoundary: true)
        if !boundaryItems.isEmpty {
            return boundaryItems
        }
        let allRowItems = detectItems(rows: rows, useSubtotalBoundary: false)
        if !allRowItems.isEmpty {
            return allRowItems
        }
        return detectItemsFallback(rows: rows)
    }

    private static func detectItems(rows: [OCRRow], useSubtotalBoundary: Bool) -> [ManualEntryPrefill.Item] {
        var detected: [ManualEntryPrefill.Item] = []
        var seenSignatures = Set<String>()
        let candidateRows = useSubtotalBoundary ? rowsForItemParsing(from: rows) : rows

        for row in candidateRows {
            let lower = row.text.lowercased()
            if shouldIgnoreItemLine(lowercasedLine: lower) { continue }

            guard let parsed = parseRetailItemRow(row) else { continue }
            let normalizedAmount = parsed.price
            if normalizedAmount == "0" || normalizedAmount == "0.0" || normalizedAmount == "0.00" { continue }
            let cleanedName = parsed.name
            let quantity = parsed.quantity

            guard cleanedName.count >= 2 else { continue }
            guard cleanedName.rangeOfCharacter(from: .letters) != nil else { continue }

            let signature = "\(cleanedName.lowercased())|\(normalizedAmount)"
            if seenSignatures.contains(signature) { continue }
            seenSignatures.insert(signature)

            detected.append(
                ManualEntryPrefill.Item(
                    name: cleanedName,
                    quantity: quantity,
                    price: normalizedAmount
                )
            )
        }

        return Array(detected.prefix(12))
    }

    private static func detectItemsFallback(rows: [OCRRow]) -> [ManualEntryPrefill.Item] {
        var results: [ManualEntryPrefill.Item] = []
        var seenSignatures = Set<String>()

        for row in rows {
            let lower = row.text.lowercased()
            if shouldIgnoreItemLine(lowercasedLine: lower) { continue }
            guard let parsed = parseLooseItemLine(row.text) else { continue }

            let signature = "\(parsed.name.lowercased())|\(parsed.price)"
            if seenSignatures.contains(signature) { continue }
            seenSignatures.insert(signature)

            results.append(
                ManualEntryPrefill.Item(
                    name: parsed.name,
                    quantity: parsed.quantity,
                    price: parsed.price
                )
            )
        }

        return Array(results.prefix(12))
    }

    private static func rowsForItemParsing(from rows: [OCRRow]) -> [OCRRow] {
        // Typical receipts list items above subtotal/total and metadata below.
        let lowercased = rows.map { $0.text.lowercased() }
        let endIndex = lowercased.firstIndex { line in
            line.contains("subtotal") || line.hasPrefix("total")
        } ?? rows.endIndex

        if endIndex > rows.startIndex {
            return Array(rows[..<endIndex])
        }
        return rows
    }

    private static func shouldIgnoreItemLine(lowercasedLine: String) -> Bool {
        if ignoredLineTokens.contains(where: { lowercasedLine.contains($0) }) {
            return true
        }

        let hardNoisePatterns = [
            #"^st#"#,
            #"^op#"#,
            #"^te#"#,
            #"^tr#"#,
            #"^ref\s*#"#,
            #"^trans"#,
            #"^\*{2,}"#,
            #"^\d{2}/\d{2}/\d{2,4}"#
        ]

        for pattern in hardNoisePatterns {
            if lowercasedLine.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    private static func extractQuantity(from line: String) -> Int {
        let patterns = [
            #"^\s*(\d+)\s*[xX]\s+"#,
            #"\bqty[:\s]*(\d+)\b"#
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: line),
                let qty = Int(line[range]),
                qty > 0
            else {
                continue
            }
            return min(qty, 99)
        }

        return 1
    }

    private static func parseRetailItemRow(_ row: OCRRow) -> (name: String, quantity: Int, price: String)? {
        if let parsed = parseRetailItemUsingSegments(row) {
            return parsed
        }
        if let parsed = parseRetailItemLineWithDecimalPrice(row.text) {
            return parsed
        }
        return parseRetailItemLineWithImpliedCents(row.text)
    }

    private static func parseRetailItemUsingSegments(_ row: OCRRow) -> (name: String, quantity: Int, price: String)? {
        guard row.segments.count >= 2 else { return nil }

        let segments = row.segments.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let hasTaxFlag = segments.contains { isSingleTaxFlag($0.text) }

        var chosenPrice: String?
        var priceIndex: Int?

        for index in segments.indices.reversed() {
            let token = segments[index].text
            if let normalized = normalizeAmount(token) {
                chosenPrice = normalized
                priceIndex = index
                break
            }
        }

        if chosenPrice == nil, hasTaxFlag {
            for index in segments.indices.reversed() {
                let token = segments[index].text.replacingOccurrences(of: ",", with: "")
                guard token.range(of: #"^\d{3,5}$"#, options: .regularExpression) != nil else { continue }
                guard let centsValue = Int(token), centsValue >= 50, centsValue <= 50_000 else { continue }
                let decimalPrice = Decimal(centsValue) / Decimal(100)
                chosenPrice = NSDecimalNumber(decimal: decimalPrice).stringValue
                priceIndex = index
                break
            }
        }

        guard let chosenPrice, let priceIndex else { return nil }

        let leftTokens = Array(segments[..<priceIndex]).map(\.text)
        let rawName = leftTokens
            .filter { !$0.isEmpty }
            .filter { $0.range(of: #"^\d{6,14}$"#, options: .regularExpression) == nil } // drop UPC-like tokens
            .joined(separator: " ")

        let cleanedName = cleanItemName(rawName)
        guard cleanedName.count >= 2 else { return nil }
        guard cleanedName.rangeOfCharacter(from: .letters) != nil else { return nil }

        let quantity = extractQuantity(from: row.text)
        return (cleanedName, quantity, chosenPrice)
    }

    private static func isSingleTaxFlag(_ token: String) -> Bool {
        token.range(of: #"^[A-Z]$"#, options: .regularExpression) != nil
    }

    private static func parseRetailItemLineWithDecimalPrice(_ line: String) -> (name: String, quantity: Int, price: String)? {
        // Prefer the last decimal amount in the line; receipt rows often include UPC before it.
        let pattern = #"([0-9]+\.[0-9]{2})\s*[A-Z]?\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let priceRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        let rawName = String(line[..<priceRange.lowerBound])
        let cleanedName = cleanItemName(rawName)
        guard cleanedName.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard let normalizedPrice = normalizeAmount(String(line[priceRange])) else { return nil }

        let quantity = extractQuantity(from: line)
        return (cleanedName, quantity, normalizedPrice)
    }

    private static func parseRetailItemLineWithImpliedCents(_ line: String) -> (name: String, quantity: Int, price: String)? {
        // Fallback for OCR that drops decimal points on item lines:
        // "DOG TREAT 007119013654 292 X" -> 2.92
        // Restrict by requiring a trailing tax/category flag to avoid address/ID lines.
        let pattern = #"^\s*(.+?)\s+(?:\d{6,14}\s+)?(\d{3,5})\s+([A-Z])\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let nameRange = Range(match.range(at: 1), in: line),
            let centsRange = Range(match.range(at: 2), in: line),
            let centsValue = Int(line[centsRange])
        else {
            return nil
        }

        // Basic sanity guard: 0.50 ... 500.00
        guard centsValue >= 50 && centsValue <= 50_000 else { return nil }

        let rawName = String(line[nameRange])
        let cleanedName = cleanItemName(rawName)
        guard cleanedName.rangeOfCharacter(from: .letters) != nil else { return nil }

        let decimalPrice = Decimal(centsValue) / Decimal(100)
        let normalizedPrice = NSDecimalNumber(decimal: decimalPrice).stringValue
        let quantity = extractQuantity(from: line)
        return (cleanedName, quantity, normalizedPrice)
    }

    private static func parseLooseItemLine(_ line: String) -> (name: String, quantity: Int, price: String)? {
        guard let price = extractAmount(from: line) ?? extractTrailingAmount(from: line) else { return nil }

        let pricePattern = #"\$?\s*[0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}|\$?\s*[0-9]+\.[0-9]{2}"#
        let name = line
            .replacingOccurrences(of: pricePattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{6,14}\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b[A-Z]\b\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleaned = cleanItemName(name)
        guard cleaned.count >= 2 else { return nil }
        guard cleaned.rangeOfCharacter(from: .letters) != nil else { return nil }

        return (cleaned, extractQuantity(from: line), price)
    }

    private static func cleanItemName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\b\d+\s*[xX]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{6,14}\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b[A-Z]\b\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAmount(from line: String) -> String? {
        let pattern = #"\$?\s*([0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}|[0-9]+\.[0-9]{2})"#
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
        return normalizeAmount(String(line[amountRange]))
    }

    private static func extractTrailingAmount(from line: String) -> String? {
        let pattern = #"\$?\s*([0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}|[0-9]+\.[0-9]{2})\s*$"#
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
        return normalizeAmount(String(line[amountRange]))
    }

    private static func normalizeAmount(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.range(of: #"^\d+(?:\.\d{2})$"#, options: .regularExpression) != nil else { return nil }
        guard let decimal = Decimal(string: cleaned) else { return nil }
        return NSDecimalNumber(decimal: decimal).stringValue
    }
}

#if os(iOS)
private struct OCRDebugView: View {
    let payload: OCRDebugPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Parsed Summary") {
                    LabeledContent("Merchant", value: payload.prefill.merchantName.isEmpty ? "—" : payload.prefill.merchantName)
                    LabeledContent("Tax", value: payload.prefill.tax.isEmpty ? "—" : payload.prefill.tax)
                    LabeledContent("Tip", value: payload.prefill.tip.isEmpty ? "—" : payload.prefill.tip)
                    LabeledContent("Items", value: "\(payload.prefill.items.count)")
                }

                Section("Parsed Items") {
                    if payload.prefill.items.isEmpty {
                        Text("No items parsed")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(payload.prefill.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                Text("qty \(item.quantity) • \(item.price)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Raw OCR Rows") {
                    ForEach(payload.scan.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.text)
                                .font(.footnote.monospaced())
                            Text("y=\(row.yCenter, specifier: "%.3f") • segments \(row.segments.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("OCR Debug")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif

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
    let currentUserID: String
    let currentUserEmail: String
    let receipts: [Receipt]
    private let splitSessionRepository = FirestoreSplitSessionRepository()
    @State private var creatingSessionReceiptID: UUID?
    @State private var sessionStatusMessage: String?
    @State private var sessionErrorMessage: String?
    @State private var joinCode: String = ""
    @State private var isJoinSheetPresented = false
    @State private var activeSessionRoute: SplitSessionRoute?

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
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(Formatters.currencyString(from: receipt.total))
                                .fontWeight(.semibold)
                            Button {
                                Task { await createSplitSession(from: receipt) }
                            } label: {
                                if creatingSessionReceiptID == receipt.id {
                                    ProgressView()
                                } else {
                                    Label("Create Session", systemImage: "person.2.badge.plus")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(creatingSessionReceiptID != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isJoinSheetPresented = true
                } label: {
                    Label("Join Session", systemImage: "link.badge.plus")
                }
            }
#else
            ToolbarItem {
                Button {
                    isJoinSheetPresented = true
                } label: {
                    Label("Join Session", systemImage: "link.badge.plus")
                }
            }
#endif
        }
        .sheet(isPresented: $isJoinSheetPresented) {
            NavigationStack {
                Form {
                    Section("Join by Invite Code") {
                        TextField("Invite Code", text: $joinCode)
#if os(iOS)
                            .textInputAutocapitalization(.characters)
#endif
                        Button("Join Session") {
                            Task { await joinSession() }
                        }
                        .disabled(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creatingSessionReceiptID != nil)
                    }
                }
                .navigationTitle("Join Session")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isJoinSheetPresented = false }
                    }
                }
            }
        }
        .navigationDestination(item: $activeSessionRoute) { route in
            SplitSessionDetailView(
                sessionID: route.id,
                currentUserID: currentUserID,
                currentUserEmail: currentUserEmail
            )
        }
        .alert("Split Session", isPresented: Binding(
            get: { sessionStatusMessage != nil },
            set: { if !$0 { sessionStatusMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionStatusMessage ?? "")
        }
        .alert("Session Error", isPresented: Binding(
            get: { sessionErrorMessage != nil },
            set: { if !$0 { sessionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionErrorMessage ?? "")
        }
    }

    private func createSplitSession(from receipt: Receipt) async {
        guard creatingSessionReceiptID == nil else { return }
        creatingSessionReceiptID = receipt.id
        defer { creatingSessionReceiptID = nil }

        do {
            let createdSession = try await splitSessionRepository.createSession(
                from: receipt,
                ownerUserId: currentUserID,
                ownerDisplayName: currentUserEmail
            )
            activeSessionRoute = SplitSessionRoute(id: createdSession.id)
        } catch {
            sessionErrorMessage = "Failed to create session. \(error.localizedDescription)"
        }
    }

    private func joinSession() async {
        guard creatingSessionReceiptID == nil else { return }
        creatingSessionReceiptID = UUID()
        defer { creatingSessionReceiptID = nil }

        do {
            let session = try await splitSessionRepository.joinSession(
                inviteCode: joinCode,
                userId: currentUserID,
                userDisplayName: currentUserEmail
            )
            joinCode = ""
            isJoinSheetPresented = false
            activeSessionRoute = SplitSessionRoute(id: session.id)
        } catch {
            sessionErrorMessage = "Join failed. \(error.localizedDescription)"
        }
    }
}

private struct SplitSessionRoute: Identifiable, Hashable {
    let id: String
}

private struct SplitSessionDetailView: View {
    let sessionID: String
    let currentUserID: String
    let currentUserEmail: String

    private let repository = FirestoreSplitSessionRepository()
    @State private var session: SplitSession?
    @State private var listener: ListenerRegistration?
    @State private var inviteCodeError: String?
    @State private var inviteCodeStatus: String?
    @State private var actionError: String?
    @State private var editingMemberID: String?
    @State private var editingDisplayName: String = ""

    var body: some View {
        List {
            if let session {
                Section("Session") {
                    LabeledContent("Session ID", value: session.id)
                    LabeledContent("Merchant", value: session.merchantName)
                    LabeledContent("Status", value: session.status)
                    if let code = session.inviteCode {
                        LabeledContent("Invite Code", value: code)
                    }
                }

                Section("Members") {
                    ForEach(session.members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                Text(member.role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.readyUserIds.contains(member.id) {
                                Text("Ready")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Text(member.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if canEditDisplayName(memberID: member.id, session: session) {
                                Button {
                                    editingMemberID = member.id
                                    editingDisplayName = member.displayName
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Items") {
                    ForEach(session.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text("x\(item.quantity) • \(Formatters.currencyString(from: item.unitPrice))")
                                    .foregroundStyle(.secondary)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(session.members) { member in
                                        Button {
                                            Task { await toggleAssignment(item: item, memberID: member.id) }
                                        } label: {
                                            Text(member.displayName)
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(item.assignedUserIds.contains(member.id) ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Live Totals") {
                    ForEach(SplitSessionCalculator.memberTotals(for: session), id: \.userId) { total in
                        let displayName = session.members.first(where: { $0.id == total.userId })?.displayName ?? total.userId
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.headline)
                            Text("Items: \(Formatters.currencyString(from: total.itemTotal))")
                            Text("Tax: \(Formatters.currencyString(from: total.taxShare))")
                            Text("Tip: \(Formatters.currencyString(from: total.tipShare))")
                            Text("Total: \(Formatters.currencyString(from: total.grandTotal))")
                                .fontWeight(.semibold)
                        }
                    }
                }

                Section("Actions") {
                    Button("Set Ready") {
                        Task { await setReady(true) }
                    }
                    .disabled(session.readyUserIds.contains(currentUserID))

                    Button("Set Not Ready") {
                        Task { await setReady(false) }
                    }
                    .disabled(!session.readyUserIds.contains(currentUserID))

                    if session.ownerUserId == currentUserID {
                        Button("Generate Invite Code") {
                            Task { await generateInviteCode(sessionID: session.id) }
                        }

                        if let code = session.inviteCode, !code.isEmpty {
                            ShareLink(item: inviteShareMessage(code: code, sessionID: session.id)) {
                                Label("Share Invite", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                copyInviteCode(code)
                            } label: {
                                Label("Copy Invite Code", systemImage: "doc.on.doc")
                            }
                        }

                        Button("Finalize Session") {
                            Task { await finalize(sessionID: session.id) }
                        }
                        .disabled(!SplitSessionAccess.canFinalize(session, userId: currentUserID))
                    }
                }
            } else {
                Section {
                    ProgressView("Loading session...")
                }
            }
        }
        .navigationTitle("Split Session")
        .task {
            startListening()
        }
        .onDisappear {
            listener?.remove()
            listener = nil
        }
        .sheet(isPresented: Binding(
            get: { editingMemberID != nil },
            set: { if !$0 { editingMemberID = nil } }
        )) {
            NavigationStack {
                Form {
                    Section("Display Name") {
                        TextField("Name", text: $editingDisplayName)
                    }
                }
                .navigationTitle("Edit Name")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            editingMemberID = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await saveDisplayName() }
                        }
                        .disabled(editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("Invite", isPresented: Binding(get: { inviteCodeStatus != nil }, set: { if !$0 { inviteCodeStatus = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteCodeStatus ?? "")
        }
        .alert("Error", isPresented: Binding(get: { actionError != nil || inviteCodeError != nil }, set: { if !$0 { actionError = nil; inviteCodeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? inviteCodeError ?? "Unknown error")
        }
    }

    private func startListening() {
        guard listener == nil else { return }
        listener = repository.observeSession(sessionID: sessionID) { updated in
            self.session = updated
        }
    }

    private func generateInviteCode(sessionID: String) async {
        do {
            let code = try await repository.createInviteCode(sessionID: sessionID, ownerUserId: currentUserID)
            inviteCodeStatus = "Invite code: \(code)"
        } catch {
            inviteCodeError = error.localizedDescription
        }
    }

    private func toggleAssignment(item: SplitSessionItem, memberID: String) async {
        guard let session else { return }
        var assigned = Set(item.assignedUserIds)
        if assigned.contains(memberID) {
            assigned.remove(memberID)
        } else {
            assigned.insert(memberID)
        }
        if assigned.isEmpty {
            assigned.insert(currentUserID)
        }
        do {
            try await repository.updateAssignments(sessionID: session.id, itemID: item.id, assignedUserIds: Array(assigned))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func setReady(_ ready: Bool) async {
        guard let session else { return }
        do {
            try await repository.setReadyState(sessionID: session.id, userId: currentUserID, isReady: ready)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func finalize(sessionID: String) async {
        do {
            try await repository.finalizeSession(sessionID: sessionID, ownerUserId: currentUserID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func inviteShareMessage(code: String, sessionID: String) -> String {
        "Join my SplitSmart session.\nInvite code: \(code)\nSession ID: \(sessionID)"
    }

    private func copyInviteCode(_ code: String) {
#if os(iOS)
        UIPasteboard.general.string = code
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
#endif
        inviteCodeStatus = "Invite code copied."
    }

    private func canEditDisplayName(memberID: String, session: SplitSession) -> Bool {
        memberID == currentUserID || session.ownerUserId == currentUserID
    }

    private func saveDisplayName() async {
        guard let memberID = editingMemberID else { return }
        do {
            try await repository.updateMemberDisplayName(
                sessionID: sessionID,
                memberID: memberID,
                displayName: editingDisplayName
            )
            editingMemberID = nil
        } catch {
            actionError = error.localizedDescription
        }
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

private struct AccountTabView: View {
    let displayName: String
    let email: String
    let initials: String
    var body: some View {
        VStack(spacing: 16) {
            Text(initials)
                .font(.system(size: 40, weight: .bold))
                .frame(width: 88, height: 88)
                .background(Color.blue.opacity(0.16))
                .clipShape(Circle())
            Text(displayName)
                .font(.title2.weight(.bold))
            Text(email)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.groupedBackground)
        .navigationTitle("Profile")
    }
}

private struct AccountProfileSheet: View {
    let email: String
    @Binding var displayName: String
    let isSaving: Bool
    let onSave: () -> Void
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Email", value: email)
                TextField("Display Name", text: $displayName)
            }

            Section {
                Button(isSaving ? "Saving..." : "Save Profile") {
                    onSave()
                }
                .disabled(isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    onSignOut()
                }
            }
        }
        .navigationTitle("Account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
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
