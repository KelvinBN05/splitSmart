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
    @State private var banner: AppBanner?

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
                            showBanner(message: "Receipt saved to history.", style: .success)
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
        .tint(AppTheme.gold)
        .toolbarBackground(AppTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
        .onChange(of: loadErrorMessage) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            showBanner(message: newValue, style: .error)
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
        .overlay(alignment: .top) {
            if let banner {
                AppBannerView(banner: banner)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: banner)
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
            showBanner(message: "Receipt deleted.", style: .success)
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
            showBanner(message: "Split saved.", style: .success)
        } catch {
            loadErrorMessage = "Failed to save split changes. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func normalizeParticipantNames(in receipt: Receipt) -> Receipt {
        var normalized = receipt
        let ownerName = effectiveCurrentUserDisplayName

        if normalized.canonicalOwnerUserId == nil || normalized.canonicalOwnerUserId?.isEmpty == true {
            normalized.canonicalOwnerUserId = currentUser.id
        }

        for index in normalized.participants.indices {
            let trimmed = normalized.participants[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.caseInsensitiveCompare("you") == .orderedSame {
                normalized.participants[index].name = ownerName
            }
        }

        return normalized
    }

    private func sendInvitesIfNeeded(for receipt: Receipt) async throws {
        guard receipt.canonicalOwnerUserId == currentUser.id else { return }

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
            showBanner(message: "Invite accepted.", style: .success)
        } catch {
            loadErrorMessage = "Failed to accept invite. \(readableCloudErrorMessage(from: error))"
        }
    }

    private func declineReceiptInvite(_ invite: ReceiptInvite) async {
        do {
            try await receiptInviteRepository.declineInvite(inviteID: invite.id, currentUserId: currentUser.id)
            await loadIncomingReceiptInvites()
            showBanner(message: "Invite declined.", style: .info)
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
            showBanner(message: "Profile updated.", style: .success)
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

    private func showBanner(message: String, style: AppBanner.Style) {
        let newBanner = AppBanner(message: message, style: style)
        banner = newBanner
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if banner?.id == newBanner.id {
                banner = nil
            }
        }
    }
}
enum Formatters {
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

enum AppTheme {
    static let ink = Color(red: 0.01, green: 0.09, blue: 0.15)
    static let navy = Color(red: 0.06, green: 0.14, blue: 0.28)
    static let royal = Color(red: 0.12, green: 0.23, blue: 0.54)
    static let gold = Color(red: 0.79, green: 0.58, blue: 0.08)
    static let goldSoft = Color(red: 0.97, green: 0.93, blue: 0.79)
    static let mist = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let surface = Color.white.opacity(0.94)
    static let line = Color(red: 0.86, green: 0.89, blue: 0.93)
    static let muted = Color(red: 0.32, green: 0.38, blue: 0.46)
    static let success = Color(red: 0.12, green: 0.54, blue: 0.34)
    static let danger = Color(red: 0.72, green: 0.18, blue: 0.18)

    static let pageGradient = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.98, blue: 1.0),
            Color(red: 0.94, green: 0.96, blue: 0.99),
            Color(red: 0.99, green: 0.98, blue: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.11, blue: 0.24),
            Color(red: 0.11, green: 0.23, blue: 0.49),
            Color(red: 0.18, green: 0.30, blue: 0.56)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AppSectionHeader: View {
    let eyebrow: String?
    let title: String
    let detail: String?

    init(_ title: String, eyebrow: String? = nil, detail: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(AppTheme.gold)
            }
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }
        }
    }
}

struct AppMetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.goldSoft.opacity(0.88))
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AppBanner: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case error
        case info
    }

    let id = UUID()
    let message: String
    let style: Style
}

private struct AppBannerView: View {
    let banner: AppBanner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
            Text(banner.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: AppTheme.navy.opacity(0.18), radius: 14, x: 0, y: 8)
    }

    private var iconName: String {
        switch banner.style {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var backgroundColor: Color {
        switch banner.style {
        case .success: return AppTheme.success
        case .error: return AppTheme.danger
        case .info: return AppTheme.royal
        }
    }
}

private struct AppCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padded: Bool

    func body(content: Content) -> some View {
        content
            .padding(padded ? 18 : 0)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.line.opacity(0.9), lineWidth: 1)
            )
            .shadow(color: AppTheme.navy.opacity(0.08), radius: 18, x: 0, y: 10)
    }
}

private struct AppInputFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.line.opacity(0.95), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: AppTheme.navy.opacity(0.03), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func appCard(cornerRadius: CGFloat = 24, padded: Bool = false) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius, padded: padded))
    }

    func appInputField() -> some View {
        modifier(AppInputFieldModifier())
    }
}

enum AppColors {
    static var groupedBackground: Color {
        AppTheme.mist
    }

    static var secondaryBackground: Color {
        Color.white.opacity(0.82)
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
