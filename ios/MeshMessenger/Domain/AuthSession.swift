import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var firebaseUser: User?
    @Published private(set) var profile: FirestoreUser?
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var isEmailVerified: Bool = false
    @Published var lastError: String?

    private let authService: AuthService
    private let userService: UserService
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    init(authService: AuthService = AuthService(), userService: UserService = UserService()) {
        self.authService = authService
        self.userService = userService
    }

    var currentUid: String? { firebaseUser?.uid }
    // Falls back to the UserDefaults cache so username is available offline even if
    // the Firestore profile fetch hasn't completed yet.
    var currentUsername: String? { profile?.username ?? cachedUsername }
    var isSignedIn: Bool { firebaseUser != nil }

    private var cachedUsername: String? {
        guard let uid = firebaseUser?.uid else { return nil }
        return UserDefaults.standard.string(forKey: "mesh_username_\(uid)")
    }

    func observeAuthState() {
        if authStateHandle != nil { return }
        // Seed immediately from the local Keychain so ContentView never briefly
        // shows LoginView for a user who was already signed in.
        if let cached = Auth.auth().currentUser {
            firebaseUser = cached
            isEmailVerified = cached.isEmailVerified
        }
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.firebaseUser = user
                self.isEmailVerified = user?.isEmailVerified ?? false
                if let user = user {
                    self.profile = try? await self.userService.get(uid: user.uid)
                    if let username = self.profile?.username {
                        UserDefaults.standard.set(username, forKey: "mesh_username_\(user.uid)")
                    }
                } else {
                    self.profile = nil
                }
            }
        }
    }

    func signUp(email: String, password: String, username: String) async {
        await run {
            let user = try await self.authService.signUp(email: email, password: password, username: username)
            self.firebaseUser = user
            self.isEmailVerified = user.isEmailVerified
            self.profile = try? await self.userService.get(uid: user.uid)
        }
    }

    func signIn(email: String, password: String) async {
        await run {
            let user = try await self.authService.signIn(email: email, password: password)
            self.firebaseUser = user
            self.isEmailVerified = user.isEmailVerified
            self.profile = try? await self.userService.get(uid: user.uid)
        }
    }

    func sendPasswordReset(to email: String) async {
        await run {
            try await self.authService.sendPasswordReset(to: email)
        }
    }

    func resendVerificationEmail() async {
        await run {
            try await self.authService.resendVerificationEmail()
        }
    }

    func refreshEmailVerified() async -> Bool {
        do {
            let verified = try await authService.refreshEmailVerified()
            self.isEmailVerified = verified
            return verified
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
    }

    func signOut() async {
        do {
            try authService.signOut()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        firebaseUser = nil
        profile = nil
        isEmailVerified = false
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isAuthenticating = true
        lastError = nil
        do { try await work() }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        isAuthenticating = false
    }
}
