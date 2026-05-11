import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: AuthSession

    var body: some View {
        Group {
            if session.isSignedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            GroupListView()
                .tabItem { Label("Groups", systemImage: "person.3") }
            RadarView()
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
        }
    }
}
