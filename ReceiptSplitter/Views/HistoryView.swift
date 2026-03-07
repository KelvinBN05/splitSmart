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

struct HistoryView: View {
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
                VStack(alignment: .leading, spacing: 12) {
                    if !incomingInvites.isEmpty {
                        inviteSection
                    }
                    if !receipts.isEmpty {
                        Text("Your Receipts")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
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

            if let createdAt = invite.createdAt {
                Text(Formatters.shortDate.string(from: createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
