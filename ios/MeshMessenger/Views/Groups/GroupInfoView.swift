import SwiftUI

struct GroupInfoView: View {
    let groupId: UUID

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var groupStore: GroupStore
    @Environment(\.dismiss) private var dismiss

    @State private var members: [FirestoreMembership] = []
    @State private var isLoading = false
    @State private var memberToRemove: FirestoreMembership?
    @State private var showConfirmLeave = false
    @State private var showConfirmDelete = false
    @State private var errorMessage: String?
    @State private var codeCopied = false
    @State private var pendingReports: [FirestoreReport] = []

    @EnvironmentObject private var blockStore: BlockStore

    private let groupService = GroupService()
    private let reportService = ReportService()
    private let mapService = MapService()

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }

    private var isAdmin: Bool {
        session.currentUid == group?.adminId
    }

    var body: some View {
        NavigationStack {
            Group {
                if let group {
                    content(group: group)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadMembers() }
    }

    @ViewBuilder
    private func content(group: LocalGroup) -> some View {
        List {
            inviteCodeSection(group: group)
            membersSection
            if isAdmin && !pendingReports.isEmpty { reportsSection }
            actionsSection
        }
        .alert(
            "Remove Member?",
            isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } })
        ) {
            Button("Remove", role: .destructive) { Task { await removeMember() } }
            Button("Cancel", role: .cancel) { memberToRemove = nil }
        } message: {
            if let m = memberToRemove { Text("Remove \(m.username) from the group?") }
        }
        .confirmationDialog("Leave Group?", isPresented: $showConfirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await leaveGroup() } }
        } message: {
            Text("You won't be able to see messages until you rejoin.")
        }
        .confirmationDialog("Delete Group?", isPresented: $showConfirmDelete, titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { Task { await deleteGroup() } }
        } message: {
            Text("This will permanently delete the group and remove all members.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
    }

    private func inviteCodeSection(group: LocalGroup) -> some View {
        Section("Invite Code") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.inviteCode)
                        .font(.system(.title2, design: .monospaced).bold())
                        .tracking(2)
                    Text("Share so others can join")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = group.inviteCode
                        codeCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            codeCopied = false
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(codeCopied ? .green : .accentColor)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    ShareLink(item: "Join my group in MeshMessenger! Use invite code: \(group.inviteCode)") {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        Section(isLoading ? "Members" : "Members (\(members.count))") {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if members.isEmpty {
                Text("No members found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members, id: \.id) { (member: FirestoreMembership) in
                    let isSelf = member.id == session.currentUid
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(member.username)
                                    .font(.body)
                                if member.id == group?.adminId {
                                    Text("Admin")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                                if !isSelf && blockStore.isBlocked(member.username) {
                                    Text("Blocked")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.12))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("Joined \(member.joinedAt.dateValue(), style: .date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isAdmin && !isSelf && member.id != group?.adminId {
                            Button {
                                memberToRemove = member
                            } label: {
                                Image(systemName: "person.badge.minus")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelf {
                            if blockStore.isBlocked(member.username) {
                                Button("Unblock") { blockStore.unblock(member.username) }
                                    .tint(.blue)
                            } else {
                                Button("Block", role: .destructive) { blockStore.block(member.username) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reportsSection: some View {
        Section("Reported Content (\(pendingReports.count))") {
            ForEach(pendingReports) { report in
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.reportType == "pin" ? "Pin by \(report.targetOwnerUid)" : "Map image")
                        .font(.subheadline.bold())
                    if !report.reason.isEmpty {
                        Text(report.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(report.createdAt.dateValue(), style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 12) {
                        Button("Remove Content") {
                            Task { await removeReportedContent(report) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)

                        Button("Dismiss") {
                            Task {
                                try? await reportService.markReviewed(groupId: report.groupId, reportId: report.id ?? "")
                                pendingReports.removeAll { $0.id == report.id }
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if isAdmin {
                Button("Delete Group", role: .destructive) {
                    showConfirmDelete = true
                }
            } else {
                Button("Leave Group", role: .destructive) {
                    showConfirmLeave = true
                }
            }
        }
    }

    private func loadMembers() async {
        isLoading = true
        do {
            members = try await groupService.members(groupId: groupId.uuidString)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        if isAdmin {
            pendingReports = (try? await reportService.pendingReports(for: groupId.uuidString)) ?? []
        }
    }

    private func removeReportedContent(_ report: FirestoreReport) async {
        if report.reportType == "pin" {
            try? await mapService.deletePin(groupId: report.groupId, pinId: report.targetId)
        }
        try? await reportService.markRemoved(groupId: report.groupId, reportId: report.id ?? "")
        pendingReports.removeAll { $0.id == report.id }
    }

    private func removeMember() async {
        guard let uid = memberToRemove?.id else { return }
        memberToRemove = nil
        await groupStore.removeMember(from: groupId, memberUid: uid)
        await loadMembers()
    }

    private func leaveGroup() async {
        await groupStore.leave(groupId: groupId)
        dismiss()
    }

    private func deleteGroup() async {
        await groupStore.deleteGroup(groupId)
        dismiss()
    }
}
