import SwiftUI

struct EmailVerificationView: View {
    @EnvironmentObject private var session: AuthSession
    @State private var checking: Bool = false
    @State private var resent: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "envelope.badge")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Verify your email")
                .font(.title2.bold())
            Text("We've sent a verification link to \(session.firebaseUser?.email ?? "your email"). Tap it, then come back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    Task {
                        checking = true
                        _ = await session.refreshEmailVerified()
                        checking = false
                    }
                } label: {
                    if checking { ProgressView() }
                    else { Text("I've verified").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await session.resendVerificationEmail()
                        resent = true
                    }
                } label: {
                    Text(resent ? "Sent again" : "Resend email")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Sign out", role: .destructive) {
                    Task { await session.signOut() }
                }
                .font(.footnote)
            }
            .padding(.horizontal)

            if let error = session.lastError {
                Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }
}
