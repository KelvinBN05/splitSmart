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

struct AccountTabView: View {
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
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("ACCOUNT")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.gold)
                    HStack(spacing: 16) {
                        Text(initials)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                            .frame(width: 84, height: 84)
                            .background(AppTheme.goldSoft)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(displayName)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                            Text(email)
                                .foregroundStyle(.white.opacity(0.78))
                            Text("Manage who can join shared bills and how your profile appears in split sessions.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.heroGradient)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    AppSectionHeader("Workspace rules", eyebrow: "Trust & Sharing")
                    Label("Private receipts synced to your account", systemImage: "lock.shield")
                    Label("Add friends once, then reuse them in manual split flows", systemImage: "person.2.badge.plus")
                    Label("OCR review before saving to history", systemImage: "doc.text.magnifyingglass")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard(cornerRadius: 22, padded: true)

                friendCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.pageGradient.ignoresSafeArea())
        .navigationTitle("Profile")
        .task {
            await reloadFriends()
        }
    }

    private var friendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppSectionHeader("Friends", eyebrow: "Network", detail: "Keep requests and active contacts in one place.")
                Spacer()
                if isLoadingFriends {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }

            VStack(spacing: 10) {
                TextField("Friend email", text: $friendEmailInput)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)
                    .appInputField()

                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    HStack {
                        Text(isMutatingFriends ? "Sending request..." : "Send friend request")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppTheme.gold)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isMutatingFriends || friendEmailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let friendErrorMessage {
                statusMessage(friendErrorMessage, color: AppTheme.danger, iconName: "exclamationmark.triangle.fill")
            } else if let friendStatusMessage {
                statusMessage(friendStatusMessage, color: AppTheme.success, iconName: "checkmark.circle.fill")
            }

            if !incomingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Incoming Requests")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    ForEach(incomingRequests) { request in
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.senderDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(request.senderEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Spacer()
                                Button("Decline") {
                                    Task { await declineRequest(request.id) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isMutatingFriends)

                                Button("Approve") {
                                    Task { await approveRequest(request.id) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.gold)
                                .controlSize(.small)
                                .disabled(isMutatingFriends)
                            }
                        }
                        .padding(14)
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.top, 2)
            }

            if !outgoingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Sent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    ForEach(outgoingRequests) { request in
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.recipientDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(request.recipientEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("Pending")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Cancel request") {
                                    Task { await cancelOutgoingRequest(request.id) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isMutatingFriends)
                            }
                        }
                        .padding(14)
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.top, 2)
            }

            if friends.isEmpty {
                Text("No friends added yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Friends")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    ForEach(friends) { friend in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
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
        .appCard(cornerRadius: 22, padded: true)
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

    private func statusMessage(_ text: String, color: Color, iconName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AccountProfileSheet: View {
    let email: String
    @Binding var displayName: String
    let isSaving: Bool
    let onSave: () -> Void
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.pageGradient
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                AppSectionHeader("Account", eyebrow: "Profile", detail: "Update the name used across split sessions.")

                VStack(alignment: .leading, spacing: 14) {
                    Text("Email")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                    Text(email)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text("Display Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                    TextField("Display Name", text: $displayName)
                        .appInputField()

                    Text("This name appears in split sessions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .appCard(cornerRadius: 24, padded: true)

                Button(isSaving ? "Saving..." : "Save Profile") {
                    onSave()
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.gold)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Sign Out", role: .destructive) {
                    onSignOut()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .padding(20)
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
