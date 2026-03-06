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

struct ContentView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let currentUser: AppUser
    let receiptRepository: ReceiptRepository
    let userProfileRepository: UserProfileRepository
    private let receiptInviteRepository = FirestoreReceiptInviteRepository()

    @State private var receipts: [Receipt] = []
    @State private var isLoadingReceipts = false
    @State private var loadErrorMessage: String?
    @State private var isAccountSheetPresented = false
    @State private var accountDisplayName = ""
    @State private var isSavingDisplayName = false
    @State private var friends: [AppFriend] = []
    @State private var incomingReceiptInvites: [ReceiptInvite] = []
    @State private var isLoadingIncomingInvites = false

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
                    userInitials: userInitials,
                    friendSuggestions: friendDisplayNames,
                    isLoadingReceipts: isLoadingReceipts,
                    loadErrorMessage: loadErrorMessage
                ) {
                    isAccountSheetPresented = true
                } onReceiptSaved: { newReceipt in
                    let normalized = normalizeParticipantNames(in: newReceipt)
                    receipts.insert(normalized, at: 0)
                    Task {
                        do {
                            try await receiptRepository.saveReceipt(normalized, ownerUserId: currentUser.id)
                            try await sendInvitesIfNeeded(for: normalized)
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
                HistoryView(
                    currentUserID: currentUser.id,
                    currentUserDisplayName: effectiveCurrentUserDisplayName,
                    receipts: receipts,
                    incomingInvites: incomingReceiptInvites,
                    friends: friends,
                    isLoadingReceipts: isLoadingReceipts,
                    isLoadingInvites: isLoadingIncomingInvites,
                    onDeleteReceipt: { receipt in
                        await deleteReceipt(receipt)
                    },
                    onSaveReceipt: { receipt in
                        await saveReceiptChanges(receipt)
                    },
                    onAcceptInvite: { invite in
                        await acceptReceiptInvite(invite)
                    },
                    onDeclineInvite: { invite in
                        await declineReceiptInvite(invite)
                    }
                )
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                AccountTabView(
                    currentUserID: currentUser.id,
                    userProfileRepository: userProfileRepository,
                    displayName: accountDisplayName.isEmpty ? defaultDisplayName : accountDisplayName,
                    email: currentUser.email ?? "unknown@example.com",
                    initials: userInitials,
                    friends: $friends
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
        .task {
            await loadFriends()
        }
        .task {
            await loadIncomingReceiptInvites()
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

    private func deleteReceipt(_ receipt: Receipt) async {
        let backup = receipts
        receipts.removeAll { $0.id == receipt.id }
        do {
            try await receiptRepository.deleteReceipt(receiptID: receipt.id, ownerUserId: currentUser.id)
        } catch {
            receipts = backup
            loadErrorMessage = "Failed to delete receipt. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func saveReceiptChanges(_ receipt: Receipt) async {
        let normalized = normalizeParticipantNames(in: receipt)

        if let index = receipts.firstIndex(where: { $0.id == normalized.id }) {
            receipts[index] = normalized
        } else {
            receipts.insert(normalized, at: 0)
        }

        do {
            try await receiptRepository.saveReceipt(normalized, ownerUserId: currentUser.id)
            try await sendInvitesIfNeeded(for: normalized)
        } catch {
            loadErrorMessage = "Failed to save split changes. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func normalizeParticipantNames(in receipt: Receipt) -> Receipt {
        var normalized = receipt
        let ownerName = effectiveCurrentUserDisplayName

        for index in normalized.participants.indices {
            let trimmed = normalized.participants[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.caseInsensitiveCompare("you") == .orderedSame {
                normalized.participants[index].name = ownerName
            }
        }

        return normalized
    }

    private func sendInvitesIfNeeded(for receipt: Receipt) async throws {
        let recipients = matchingFriends(from: receipt)
        guard !recipients.isEmpty else { return }

        try await receiptInviteRepository.sendInvites(
            receipt: receipt,
            ownerUserId: currentUser.id,
            ownerDisplayName: accountDisplayName.isEmpty ? defaultDisplayName : accountDisplayName,
            ownerEmail: currentUser.email ?? "unknown@example.com",
            recipients: recipients
        )
    }

    private func matchingFriends(from receipt: Receipt) -> [AppFriend] {
        let participantNames = Set(
            receipt.participants.map {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )

        return friends.filter { friend in
            guard friend.id != currentUser.id else { return false }
            let display = friend.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return participantNames.contains(display)
        }
    }

    private func loadIncomingReceiptInvites() async {
        guard !isLoadingIncomingInvites else { return }
        isLoadingIncomingInvites = true
        defer { isLoadingIncomingInvites = false }

        do {
            incomingReceiptInvites = try await receiptInviteRepository.fetchIncomingInvites(userId: currentUser.id)
        } catch {
            loadErrorMessage = "Failed to load invites. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func acceptReceiptInvite(_ invite: ReceiptInvite) async {
        do {
            try await receiptInviteRepository.acceptInvite(inviteID: invite.id, currentUserId: currentUser.id)
            await loadIncomingReceiptInvites()
            await loadReceipts()
        } catch {
            loadErrorMessage = "Failed to accept invite. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func declineReceiptInvite(_ invite: ReceiptInvite) async {
        do {
            try await receiptInviteRepository.declineInvite(inviteID: invite.id, currentUserId: currentUser.id)
            await loadIncomingReceiptInvites()
        } catch {
            loadErrorMessage = "Failed to decline invite. \(readableCloudErrorMessage(from: error))"
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

    private var effectiveCurrentUserDisplayName: String {
        let trimmed = accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDisplayName : trimmed
    }

    private var friendDisplayNames: [String] {
        friends
            .map { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ($0.email.components(separatedBy: "@").first ?? "Friend") : $0.displayName }
            .sorted()
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

    private func loadFriends() async {
        do {
            friends = try await userProfileRepository.fetchFriends(userID: currentUser.id)
        } catch {
            // Non-blocking: show app even if friends fetch fails.
        }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("SplitSmart")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.22))
                    .minimumScaleFactor(0.85)
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
                    ManualEntryView(friendSuggestions: friendSuggestions, onReceiptSaved: onReceiptSaved)
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
                Text("See All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
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

private struct HistoryView: View {
    let currentUserID: String
    let currentUserDisplayName: String
    let receipts: [Receipt]
    let incomingInvites: [ReceiptInvite]
    let friends: [AppFriend]
    let isLoadingReceipts: Bool
    let isLoadingInvites: Bool
    let onDeleteReceipt: (Receipt) async -> Void
    let onSaveReceipt: (Receipt) async -> Void
    let onAcceptInvite: (ReceiptInvite) async -> Void
    let onDeclineInvite: (ReceiptInvite) async -> Void

    @State private var deleteCandidate: Receipt?
    @State private var selectedReceipt: Receipt?

    var body: some View {
        historyContent
        .background(AppColors.groupedBackground)
        .navigationTitle("History")
        .navigationDestination(item: $selectedReceipt) { receipt in
            ReceiptSplitOverviewView(
                receipt: receipt,
                currentUserDisplayName: currentUserDisplayName,
                friends: friends
            ) { updatedReceipt in
                await onSaveReceipt(updatedReceipt)
            }
        }
        .alert("Delete Receipt?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let receipt = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await onDeleteReceipt(receipt) }
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text("This receipt will be removed from your history.")
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if isLoadingReceipts && isLoadingInvites && receipts.isEmpty && incomingInvites.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading history...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if receipts.isEmpty && incomingInvites.isEmpty {
            ContentUnavailableView(
                "No Receipts Yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Add a receipt from Home to see your history.")
            )
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    if !incomingInvites.isEmpty {
                        inviteSection
                    }
                    ForEach(receipts) { receipt in
                        receiptCard(receipt)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipt Invites")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            ForEach(incomingInvites) { invite in
                inviteCard(invite)
            }
        }
    }

    private func inviteCard(_ invite: ReceiptInvite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.receipt.merchantName)
                        .font(.headline)
                    Text("From \(invite.senderDisplayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.currencyString(from: invite.receipt.total))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await onAcceptInvite(invite) }
                } label: {
                    Label("Accept", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task { await onDeclineInvite(invite) }
                } label: {
                    Label("Decline", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }

    private func receiptCard(_ receipt: Receipt) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.merchantName)
                        .font(.headline)
                    Text(Formatters.numericDate.string(from: receipt.createdAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.currencyString(from: receipt.total))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
            }

            HStack(spacing: 10) {
                Button {
                    selectedReceipt = receipt
                } label: {
                    Label("Split Overview", systemImage: "person.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    deleteCandidate = receipt
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedReceipt = receipt
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

private struct ReceiptSplitOverviewView: View {
    let receipt: Receipt
    let currentUserDisplayName: String
    let friends: [AppFriend]
    let onSave: (Receipt) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Receipt
    @State private var customPersonName: String = ""
    @State private var isSaving = false

    init(
        receipt: Receipt,
        currentUserDisplayName: String,
        friends: [AppFriend],
        onSave: @escaping (Receipt) async -> Void
    ) {
        self.receipt = receipt
        self.currentUserDisplayName = currentUserDisplayName
        self.friends = friends
        self.onSave = onSave

        var normalized = receipt
        if normalized.participants.isEmpty {
            normalized.participants = [Participant(name: currentUserDisplayName)]
        }
        for index in normalized.items.indices {
            if normalized.items[index].assignedParticipantIDs.isEmpty,
               let fallback = normalized.participants.first?.id {
                normalized.items[index].assignedParticipantIDs = [fallback]
            }
        }
        _draft = State(initialValue: normalized)
    }

    var body: some View {
        Form {
            Section("Receipt") {
                LabeledContent("Merchant", value: draft.merchantName)
                LabeledContent("Date", value: Formatters.numericDate.string(from: draft.createdAt))
                LabeledContent("Total", value: Formatters.currencyString(from: draft.total))
            }

            Section("People") {
                ForEach(draft.participants) { participant in
                    HStack {
                        Text(participant.name)
                        Spacer()
                        if canRemoveParticipant(participant) {
                            Button(role: .destructive) {
                                removeParticipant(participant)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Menu {
                    ForEach(addableFriends) { friend in
                        Button(friend.displayName) {
                            addParticipant(name: friend.displayName)
                        }
                    }
                } label: {
                    Label("Add Friend", systemImage: "person.badge.plus")
                }
                .disabled(addableFriends.isEmpty)

                HStack {
                    TextField("Add person (non-user)", text: $customPersonName)
                    Button("Add") {
                        addParticipant(name: customPersonName)
                    }
                    .disabled(customPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Split Assignments") {
                ForEach(draft.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(Formatters.currencyString(from: item.subtotal))
                                .foregroundStyle(.secondary)
                        }
                        Text("Split With")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(draft.participants) { participant in
                            Button {
                                toggleParticipantAssignment(itemID: item.id, participantID: participant.id)
                            } label: {
                                HStack {
                                    Image(systemName: isAssigned(itemID: item.id, participantID: participant.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isAssigned(itemID: item.id, participantID: participant.id) ? Color.accentColor : .secondary)
                                    Text(participant.name)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Overview") {
                ForEach(SplitCalculator.calculate(receipt: draft)) { row in
                    HStack {
                        Text(row.participant.name)
                        Spacer()
                        Text(Formatters.currencyString(from: row.grandTotal))
                            .fontWeight(.semibold)
                    }
                }
            }

            Section("Actions") {
                Button {
                    Task { await saveAndClose() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Save Split")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Split Overview")
    }

    private var addableFriends: [AppFriend] {
        let existing = Set(draft.participants.map { $0.name.lowercased() })
        return friends.filter { !existing.contains($0.displayName.lowercased()) }
    }

    private func addParticipant(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !draft.participants.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        draft.participants.append(Participant(name: trimmed))
        customPersonName = ""
    }

    private func canRemoveParticipant(_ participant: Participant) -> Bool {
        draft.participants.count > 1
    }

    private func removeParticipant(_ participant: Participant) {
        guard canRemoveParticipant(participant) else { return }
        guard let fallback = draft.participants.first(where: { $0.id != participant.id }) else { return }
        draft.participants.removeAll { $0.id == participant.id }
        for index in draft.items.indices {
            if draft.items[index].assignedParticipantIDs.contains(participant.id) {
                draft.items[index].assignedParticipantIDs = [fallback.id]
            }
        }
    }

    private func isAssigned(itemID: UUID, participantID: UUID) -> Bool {
        guard let item = draft.items.first(where: { $0.id == itemID }) else { return false }
        return item.assignedParticipantIDs.contains(participantID)
    }

    private func toggleParticipantAssignment(itemID: UUID, participantID: UUID) {
        guard let index = draft.items.firstIndex(where: { $0.id == itemID }) else { return }
        if draft.items[index].assignedParticipantIDs.contains(participantID) {
            if draft.items[index].assignedParticipantIDs.count == 1 { return }
            draft.items[index].assignedParticipantIDs.remove(participantID)
        } else {
            draft.items[index].assignedParticipantIDs.insert(participantID)
        }
    }

    private func saveAndClose() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        await onSave(draft)
        dismiss()
    }
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
                            if editingMemberID == member.id {
                                TextField("Display Name", text: $editingDisplayName)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName)
                                    Text(member.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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
                                if editingMemberID == member.id {
                                    HStack(spacing: 10) {
                                        Button {
                                            editingMemberID = nil
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            Task { await saveDisplayName() }
                                        } label: {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                } else {
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

private struct AccountTabView: View {
    let currentUserID: String
    let userProfileRepository: UserProfileRepository
    let displayName: String
    let email: String
    let initials: String
    @Binding var friends: [AppFriend]

    @State private var friendEmailInput = ""
    @State private var friendErrorMessage: String?
    @State private var friendStatusMessage: String?
    @State private var isMutatingFriends = false
    @State private var isLoadingFriends = false
    @State private var incomingRequests: [FriendRequest] = []
    @State private var outgoingRequests: [FriendRequest] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
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
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Private receipts synced to your account", systemImage: "lock.shield")
                    Label("Add friends once, then reuse them in manual split flows", systemImage: "person.2.badge.plus")
                    Label("OCR review before saving to history", systemImage: "doc.text.magnifyingglass")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )

                friendCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.groupedBackground)
        .navigationTitle("Profile")
        .task {
            await reloadFriends()
        }
    }

    private var friendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Friends", systemImage: "person.3")
                    .font(.headline)
                Spacer()
                if isLoadingFriends {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }

            HStack(spacing: 8) {
                TextField("Friend email", text: $friendEmailInput)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(AppColors.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    Text(isMutatingFriends ? "Sending..." : "Send")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isMutatingFriends || friendEmailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let friendErrorMessage {
                Text(friendErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let friendStatusMessage {
                Text(friendStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if !incomingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Incoming Requests")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))

                    ForEach(incomingRequests) { request in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.senderDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(request.senderEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Approve") {
                                Task { await approveRequest(request.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isMutatingFriends)

                            Button("Decline") {
                                Task { await declineRequest(request.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isMutatingFriends)
                        }
                    }
                }
            }

            if !outgoingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Sent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))

                    ForEach(outgoingRequests) { request in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.recipientDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(request.recipientEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Pending")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Button("Cancel") {
                                Task { await cancelOutgoingRequest(request.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isMutatingFriends)
                        }
                    }
                }
            }

            if friends.isEmpty {
                Text("No friends added yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Friends")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                    ForEach(friends) { friend in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                                Text(friend.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private func reloadFriends() async {
        guard !isLoadingFriends else { return }
        isLoadingFriends = true
        defer { isLoadingFriends = false }
        do {
            async let fetchedFriends = userProfileRepository.fetchFriends(userID: currentUserID)
            async let fetchedIncoming = userProfileRepository.fetchIncomingFriendRequests(userID: currentUserID)
            async let fetchedOutgoing = userProfileRepository.fetchOutgoingFriendRequests(userID: currentUserID)

            friends = try await fetchedFriends
            incomingRequests = try await fetchedIncoming
            outgoingRequests = try await fetchedOutgoing
        } catch {
            friendErrorMessage = "Could not load friends."
        }
    }

    private func sendFriendRequest() async {
        guard !isMutatingFriends else { return }
        isMutatingFriends = true
        defer { isMutatingFriends = false }
        friendErrorMessage = nil
        friendStatusMessage = nil

        do {
            try await userProfileRepository.sendFriendRequest(
                currentUserID: currentUserID,
                friendEmail: friendEmailInput
            )
            friendEmailInput = ""
            await reloadFriends()
            friendStatusMessage = "Friend request sent."
        } catch {
            friendErrorMessage = error.localizedDescription
        }
    }

    private func approveRequest(_ requestID: String) async {
        guard !isMutatingFriends else { return }
        isMutatingFriends = true
        defer { isMutatingFriends = false }
        friendErrorMessage = nil
        friendStatusMessage = nil

        do {
            try await userProfileRepository.acceptFriendRequest(currentUserID: currentUserID, requestID: requestID)
            await reloadFriends()
            friendStatusMessage = "Friend request approved."
        } catch {
            friendErrorMessage = error.localizedDescription
        }
    }

    private func declineRequest(_ requestID: String) async {
        guard !isMutatingFriends else { return }
        isMutatingFriends = true
        defer { isMutatingFriends = false }
        friendErrorMessage = nil
        friendStatusMessage = nil

        do {
            try await userProfileRepository.declineFriendRequest(currentUserID: currentUserID, requestID: requestID)
            await reloadFriends()
            friendStatusMessage = "Friend request declined."
        } catch {
            friendErrorMessage = error.localizedDescription
        }
    }

    private func cancelOutgoingRequest(_ requestID: String) async {
        guard !isMutatingFriends else { return }
        isMutatingFriends = true
        defer { isMutatingFriends = false }
        friendErrorMessage = nil
        friendStatusMessage = nil

        do {
            try await userProfileRepository.cancelOutgoingFriendRequest(currentUserID: currentUserID, requestID: requestID)
            await reloadFriends()
            friendStatusMessage = "Request canceled."
        } catch {
            friendErrorMessage = error.localizedDescription
        }
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
                Text("This name appears in split sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .presentationDetents([.medium, .large])
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

private struct AppCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

private extension View {
    func appCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius))
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
