import SwiftUI

struct GroupDetailView: View {
    let groupId: UUID

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var groupStore: GroupStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var showGroupInfo = false

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(groupId: groupId)
                .tabItem { Label("Chat", systemImage: "message") }
                .tag(0)

            GroupRadarView(groupId: groupId)
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)

            GroupMapView(groupId: groupId)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(2)
        }
        .navigationTitle(group?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGroupInfo = true } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoView(groupId: groupId)
                .environmentObject(session)
                .environmentObject(groupStore)
        }
        .onChange(of: groupStore.groups.map(\.id)) { _, ids in
            if !ids.contains(groupId) { dismiss() }
        }
    }
}
