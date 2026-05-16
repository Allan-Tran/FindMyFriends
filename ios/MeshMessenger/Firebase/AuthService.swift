import Foundation
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

enum AuthError: LocalizedError {
    case usernameTaken
    case invalidUsername
    case weakPassword
    case missingUser
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "That username is already taken."
        case .invalidUsername: return "Username must be 3–32 letters, digits, '_' or '.'."
        case .weakPassword: return "Password must be at least 8 characters."
        case .missingUser: return "No signed-in user."
        case .underlying(let e): return e.localizedDescription
        }
    }
}

struct AuthService: Sendable {
    let auth: Auth
    let db: Firestore

    init(auth: Auth = .auth(), db: Firestore = .firestore()) {
        self.auth = auth
        self.db = db
    }

    /// Sign up with email + password. Reserves the username atomically and
    /// creates the user profile doc. Sends a verification email.
    func signUp(email: String, password: String, username: String) async throws -> User {
        let normalisedUsername = username.trimmingCharacters(in: .whitespaces)
        guard isValidUsername(normalisedUsername) else { throw AuthError.invalidUsername }
        guard password.count >= 8 else { throw AuthError.weakPassword }

        let usernameLower = normalisedUsername.lowercased()
        let reservationRef = db.collection("usernames").document(usernameLower)
        let existing = try? await reservationRef.getDocument()
        if existing?.exists == true { throw AuthError.usernameTaken }

        let result: AuthDataResult
        do {
            result = try await auth.createUser(withEmail: email, password: password)
        } catch {
            throw AuthError.underlying(error)
        }

        let uid = result.user.uid
        let now = Timestamp(date: Date())

        let batch = db.batch()
        batch.setData(["uid": uid], forDocument: reservationRef)
        batch.setData([
            "email": email,
            "username": normalisedUsername,
            "usernameLower": usernameLower,
            "createdAt": now,
            "emailVerified": result.user.isEmailVerified
        ], forDocument: db.collection("users").document(uid))

        do {
            try await batch.commit()
        } catch {
            try? await result.user.delete()
            throw AuthError.underlying(error)
        }

        try? await result.user.sendEmailVerification()
        return result.user
    }

    func signIn(email: String, password: String) async throws -> User {
        do {
            let result = try await auth.signIn(withEmail: email, password: password)
            return result.user
        } catch {
            throw AuthError.underlying(error)
        }
    }

    func signOut() throws {
        try auth.signOut()
    }

    func sendPasswordReset(to email: String) async throws {
        do { try await auth.sendPasswordReset(withEmail: email) }
        catch { throw AuthError.underlying(error) }
    }

    func resendVerificationEmail() async throws {
        guard let user = auth.currentUser else { throw AuthError.missingUser }
        do { try await user.sendEmailVerification() }
        catch { throw AuthError.underlying(error) }
    }

    /// Force-refresh the user record and write back the verified flag on the profile doc.
    func refreshEmailVerified() async throws -> Bool {
        guard let user = auth.currentUser else { throw AuthError.missingUser }
        try await user.reload()
        let verified = user.isEmailVerified
        if verified {
            // Firestore rules evaluate request.auth.token.email_verified from the JWT,
            // not the local SDK flag. Force a new token so the claim is current.
            _ = try? await user.getIDTokenResult(forcingRefresh: true)
        }
        try await db.collection("users").document(user.uid).updateData([
            "emailVerified": verified
        ])
        return verified
    }

    private func isValidUsername(_ u: String) -> Bool {
        guard (3...32).contains(u.count) else { return false }
        for c in u {
            if !(c.isLetter || c.isNumber || c == "_" || c == ".") { return false }
        }
        return true
    }
}
