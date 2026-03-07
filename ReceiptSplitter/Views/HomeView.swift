import SwiftUI
import FirebaseFirestore
#if os(iOS)
import UIKit
import PhotosUI
import FirebaseStorage
import Vision
import VisionKit
import CoreImage
import CoreImage.CIFilterBuiltins
#elseif os(macOS)
import AppKit
#endif

struct HomeView: View {
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
    let friendSuggestions: [String]
    let isLoadingReceipts: Bool
    let loadErrorMessage: String?
    let onAccountTapped: () -> Void
    let onReceiptSaved: (Receipt) -> Void
#if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isDocumentScannerPresented = false
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
            VStack(alignment: .leading, spacing: 22) {
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
        .navigationTitle("Home")
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
            ManualEntryView(prefill: prefill, friendSuggestions: friendSuggestions) { savedReceipt in
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
#if os(iOS)
        .sheet(isPresented: $isDocumentScannerPresented) {
            DocumentReceiptScannerView { scannedImage in
                isDocumentScannerPresented = false
                Task {
                    await processCapturedImage(scannedImage)
                }
            } onCancel: {
                isDocumentScannerPresented = false
            }
        }
#endif
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome back")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.22))
                Text("Scan, split, and share receipts.")
                    .font(.subheadline)
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
            .accessibilityLabel("Open account")
        }
    }

    private var scanCard: some View {
#if os(iOS)
        Button {
            isDocumentScannerPresented = true
        } label: {
            scanCardBody
        }
        .buttonStyle(.plain)
        .disabled(isProcessingPhoto || isBusy)
#else
        scanCardBody
#endif
    }

    private var scanCardBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "camera")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.2))
                .clipShape(Circle())

            Text("Scan Receipt")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.85)

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
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))

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
                    ManualEntryView(friendSuggestions: friendSuggestions, onReceiptSaved: onReceiptSaved)
                } label: {
                    SmallActionCard(title: "Manual Entry", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            Text("Scan Status")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

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
            try await processImageData(data)
            selectedPhotoItem = nil
        } catch {
            photoProcessingError = error.localizedDescription
            scanFlowStage = .failed
            scanFlowDetail = error.localizedDescription
        }
    }

    private func processCapturedImage(_ image: UIImage) async {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        photoProcessingError = nil
        scanFlowStage = .uploading
        scanFlowDetail = "Preparing captured image."
        defer { isProcessingPhoto = false }

        do {
            guard let imageData = image.jpegData(compressionQuality: 0.92) else {
                throw NSError(domain: "Scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode captured image."])
            }
            try await processImageData(imageData)
        } catch {
            photoProcessingError = error.localizedDescription
            scanFlowStage = .failed
            scanFlowDetail = error.localizedDescription
        }
    }

    private func processImageData(_ imageData: Data) async throws {
        let prefill = try await DocumentAIOCRJobService.createAndAwaitOCRJob(
            imageData: imageData,
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
    }
#endif

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Spacer()
                Text("\(receipts.count) total")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isLoadingReceipts {
                LoadingActivityCard()
            } else if let loadErrorMessage, receipts.isEmpty {
                ErrorActivityCard(message: loadErrorMessage)
            } else if receipts.isEmpty {
                EmptyActivityCard()
            } else {
                ForEach(receipts.prefix(2)) { receipt in
                    ActivityRow(receipt: receipt)
                }
            }
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
        .appCard(cornerRadius: 24)
    }
}

private struct LoadingActivityCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading recent activity...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appCard(cornerRadius: 24)
    }
}

private struct ErrorActivityCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Could not load activity")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appCard(cornerRadius: 24)
    }
}

#if os(iOS)
private struct DocumentReceiptScannerView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                onCancel()
                return
            }
            let image = scan.imageOfPage(at: 0)
            onCapture(image)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

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
        .appCard(cornerRadius: 24)
        .accessibilityElement(children: .combine)
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
        .appCard(cornerRadius: 24)
        .accessibilityElement(children: .combine)
    }
}
