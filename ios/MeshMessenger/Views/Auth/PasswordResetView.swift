import SwiftUI

struct PasswordResetView: View {
    @EnvironmentObject private var session: AuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var sent: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Reset password")
                } footer: {
                    Text("We'll email you a link to set a new password.")
                }
                if sent {
                    Section {
                        Text("Email sent. Check your inbox.").foregroundStyle(.green)
                    }
                }
                if let error = session.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reset password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send link") {
                        Task {
                            await session.sendPasswordReset(to: email)
                            if session.lastError == nil { sent = true }
                        }
                    }
                    .disabled(!email.contains("@") || session.isAuthenticating)
                }
            }
        }
    }
}
