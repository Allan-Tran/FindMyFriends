import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AuthSession
    @State private var phoneNumber: String = ""
    @State private var step: LoginStep = .phone
    @State private var otp: String = ""
    @State private var username: String = ""

    enum LoginStep { case phone, otp }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("Mesh Messenger")
                .font(.largeTitle.bold())

            switch step {
            case .phone:
                phoneEntry
            case .otp:
                otpEntry
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
    }

    private var phoneEntry: some View {
        VStack(spacing: 12) {
            Text("Enter your phone number to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("+1 555 555 5555", text: $phoneNumber)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
            Button {
                Task {
                    await session.requestOtp(phoneNumber: phoneNumber)
                    if session.lastError == nil { step = .otp }
                }
            } label: {
                if session.isAuthenticating {
                    ProgressView()
                } else {
                    Text("Send code").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isAuthenticating || phoneNumber.count < 7)
        }
    }

    private var otpEntry: some View {
        VStack(spacing: 12) {
            Text("Enter the 6-digit code we sent to \(phoneNumber).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("123456", text: $otp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            TextField("Username (only needed on first sign-in)", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)
            Button {
                Task {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    await session.verifyOtp(otp: otp, username: u.isEmpty ? nil : u)
                }
            } label: {
                if session.isAuthenticating {
                    ProgressView()
                } else {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isAuthenticating || otp.count < 4)

            Button("Use a different number") { step = .phone; otp = "" }
                .font(.footnote)
        }
    }
}
