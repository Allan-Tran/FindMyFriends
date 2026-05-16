import SwiftUI
import UserNotifications

struct ContentView: View {
    @EnvironmentObject private var session: AuthSession

    var body: some View {
        Group {
            if !session.isSignedIn {
                LoginView()
            } else if !session.isEmailVerified {
                EmailVerificationView()
            } else {
                MainTabView()
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var dmStore: DMStore

    private var totalUnread: Int { groupStore.totalUnreadCount + dmStore.totalUnreadCount }

    var body: some View {
        TabView {
            GroupListView()
                .tabItem { Label("Groups", systemImage: "person.3") }
                .badge(groupStore.totalUnreadCount > 0 ? groupStore.totalUnreadCount : 0)
            MessagesView()
                .tabItem { Label("Messages", systemImage: "message") }
                .badge(dmStore.totalUnreadCount > 0 ? dmStore.totalUnreadCount : 0)
        }
        .task {
            try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
        }
        .onChange(of: totalUnread) { _, count in
            Task {
                try? await UNUserNotificationCenter.current().setBadgeCount(count)
            }
        }
    }
}
