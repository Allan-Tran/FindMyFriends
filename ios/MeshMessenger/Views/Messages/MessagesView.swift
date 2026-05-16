import SwiftUI

enum ConversationDestination: Hashable {
    case group(UUID)
    case dm(UUID, String)
}

struct MessagesView: View {
    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var dmStore: DMStore

    var body: some View {
        NavigationStack {
            List {
                groupsSection
                dmsSection
            }
            .navigationTitle("Messages")
            .navigationDestination(for: ConversationDestination.self) { dest in
                switch dest {
                case .group(let id):
                    GroupDetailView(groupId: id)
                case .dm(let id, let peer):
                    DirectChatView(dmId: id, peerUsername: peer)
                }
            }
            .task {
                groupStore.loadLocal()
                groupStore.startObserving()
                dmStore.load()
                syncRouterGroups()
            }
            .onChange(of: groupStore.groups.map(\.id)) { _, _ in syncRouterGroups() }
            .onChange(of: session.currentUsername) { _, name in
                guard name != nil else { return }
                syncRouterGroups()
            }
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        if !groupStore.groups.isEmpty {
            Section("Groups") {
                ForEach(groupStore.groups) { group in
                    NavigationLink(value: ConversationDestination.group(group.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.headline)
                                Text("\(group.memberUsernames.count) member\(group.memberUsernames.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if group.unreadCount > 0 {
                                Text("\(group.unreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.red, in: Capsule())
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dmsSection: some View {
        if !dmStore.conversations.isEmpty {
            Section("Direct Messages") {
                ForEach(dmStore.conversations) { conv in
                    NavigationLink(value: ConversationDestination.dm(conv.id, conv.peerUsername)) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(conv.peerUsername)
                                .font(.headline)
                            Spacer()
                            if conv.unreadCount > 0 {
                                Text("\(conv.unreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.red, in: Capsule())
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    private func syncRouterGroups() {
        let ids = Set(groupStore.groups.map(\.id))
        guard let username = session.currentUsername else { return }
        if !router.meshEngine.isRunning {
            router.start(username: username, groupIds: ids)
        } else {
            router.updateActiveGroups(ids)
        }
    }
}
