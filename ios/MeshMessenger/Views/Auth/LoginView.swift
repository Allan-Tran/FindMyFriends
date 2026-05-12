import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AuthSession
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var showSignUp = false
    @State private var showPasswordReset = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                Text("Mesh Messenger")
                    .font(.largeTitle.bold())

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await session.signIn(email: email, password: password) }
                    } label: {
                        if session.isAuthenticating {
                            ProgressView()
                        } else {
                            Text("Sign in").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isAuthenticating || !canSubmit)

                    HStack {
                        Button("Forgot password?") { showPasswordReset = true }
                            .font(.footnote)
                        Spacer()
                        Button("Create account") { showSignUp = true }
                            .font(.footnote)
                    }
                }

                if let error = session.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .sheet(isPresented: $showSignUp) {
                SignUpView().environmentObject(session)
            }
            .sheet(isPresented: $showPasswordReset) {
                PasswordResetView().environmentObject(session)
            }
        }
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 8
    }
}
