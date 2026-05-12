import SwiftUI

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
    var body: some View {
        TabView {
            GroupListView()
                .tabItem { Label("Groups", systemImage: "person.3") }
            RadarView()
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
        }
    }
}
