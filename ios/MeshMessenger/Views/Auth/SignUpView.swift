import SwiftUI

struct SignUpView: View {
    @EnvironmentObject private var session: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var username: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    SecureField("Password (8+ chars)", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                }
                Section("Profile") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                if let error = session.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if !mismatchHint.isEmpty {
                    Section {
                        Text(mismatchHint).foregroundStyle(.orange).font(.footnote)
                    }
                }
            }
            .navigationTitle("Create account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign up") {
                        Task {
                            await session.signUp(email: email, password: password, username: username)
                            if session.lastError == nil && session.isSignedIn { dismiss() }
                        }
                    }
                    .disabled(!canSubmit || session.isAuthenticating)
                }
            }
        }
    }

    private var canSubmit: Bool {
        email.contains("@") &&
        password.count >= 8 &&
        password == confirmPassword &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var mismatchHint: String {
        if !password.isEmpty && password != confirmPassword { return "Passwords don't match" }
        return ""
    }
}
