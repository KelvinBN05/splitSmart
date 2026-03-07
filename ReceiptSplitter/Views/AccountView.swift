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
                VStack(spacing: 10) {
                    Text("Account")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                .padding(.top, 2)
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

struct AccountProfileSheet: View {
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
