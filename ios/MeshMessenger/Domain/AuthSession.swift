import Foundation
import Combine

@MainActor
final class AuthSession: ObservableObject, AccessTokenProvider {
    @Published private(set) var session: StoredSession?
    @Published private(set) var isAuthenticating: Bool = false
    @Published var lastError: String?

    private var pendingPhoneNumber: String?
    private lazy var unauthedClient: APIClient = APIClient(tokenProvider: nil)
    private lazy var authedClient: APIClient = APIClient(tokenProvider: self)
    private lazy var authAPI: AuthAPI = AuthAPI(client: unauthedClient)
    private(set) lazy var apiClient: APIClient = authedClient

    private var refreshInFlight: Task<String, Error>?

    init() {
        self.session = TokenStore.load()
    }

    var isSignedIn: Bool { session != nil }
    var currentUserId: UUID? { session?.userId }
    var currentUsername: String? { session?.username }

    func currentAccessToken() async -> String? {
        guard let s = session else { return nil }
        if Date() < s.accessTokenExpiresAt.addingTimeInterval(-30) {
            return s.accessToken
        }
        return try? await refresh()
    }

    func refresh() async throws -> String {
        if let existing = refreshInFlight { return try await existing.value }
        let task = Task<String, Error> { [weak self] in
            defer { Task { @MainActor in self?.refreshInFlight = nil } }
            guard let self else { throw APIError.notAuthenticated }
            guard let s = self.session else { throw APIError.notAuthenticated }
            let result = try await self.authAPI.refresh(refreshToken: s.refreshToken)
            let new = StoredSession(
                accessToken: result.accessToken,
                accessTokenExpiresAt: result.accessTokenExpiresAt,
                refreshToken: result.refreshToken,
                refreshTokenExpiresAt: result.refreshTokenExpiresAt,
                userId: result.userId,
                username: result.username
            )
            try TokenStore.save(new)
            await MainActor.run { self.session = new }
            return new.accessToken
        }
        refreshInFlight = task
        return try await task.value
    }

    func requestOtp(phoneNumber: String) async {
        isAuthenticating = true
        lastError = nil
        do {
            try await authAPI.requestOtp(phoneNumber: phoneNumber)
            pendingPhoneNumber = phoneNumber
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        isAuthenticating = false
    }

    func verifyOtp(otp: String, username: String?) async {
        guard let phone = pendingPhoneNumber else {
            lastError = "Request a code first"
            return
        }
        isAuthenticating = true
        lastError = nil
        do {
            let result = try await authAPI.verifyOtp(phoneNumber: phone, otp: otp, username: username)
            let new = StoredSession(
                accessToken: result.accessToken,
                accessTokenExpiresAt: result.accessTokenExpiresAt,
                refreshToken: result.refreshToken,
                refreshTokenExpiresAt: result.refreshTokenExpiresAt,
                userId: result.userId,
                username: result.username
            )
            try TokenStore.save(new)
            self.session = new
            self.pendingPhoneNumber = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        isAuthenticating = false
    }

    func signOut() async {
        if let s = session {
            try? await authAPI.logout(refreshToken: s.refreshToken)
        }
        TokenStore.clear()
        PeerIdentity.reset()
        session = nil
    }
}
