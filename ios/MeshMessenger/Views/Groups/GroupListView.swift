import SwiftUI
import SwiftData

struct GroupListView: View {
    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var dmStore: DMStore
    @State private var showCreate = false
    @State private var showJoin = false

    var body: some View {
        NavigationStack {
            List {
                if groupStore.groups.isEmpty {
                    ContentUnavailableView(
                        "No groups yet",
                        systemImage: "person.3",
                        description: Text("Create a new group or join one with an invite code.")
                    )
                } else {
                    ForEach(groupStore.groups) { group in
                        NavigationLink(value: group.id) {
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
            .navigationTitle("Groups")
            .navigationDestination(for: UUID.self) { id in
                GroupDetailView(groupId: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Sign out", role: .destructive) {
                            Task { await session.signOut() }
                        }
                    } label: {
                        Label(session.currentUsername ?? "Me", systemImage: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create group", systemImage: "plus") { showCreate = true }
                        Button("Join with code", systemImage: "key") { showJoin = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateGroupView()
                    .environmentObject(groupStore)
                    .environmentObject(router)
            }
            .sheet(isPresented: $showJoin) {
                JoinGroupView()
                    .environmentObject(groupStore)
                    .environmentObject(router)
            }
            .task {
                groupStore.loadLocal()
                groupStore.startObserving()
                dmStore.load()
                syncRouterGroups()
            }
            .onChange(of: groupStore.groups.map(\.id)) { _, _ in
                syncRouterGroups()
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

