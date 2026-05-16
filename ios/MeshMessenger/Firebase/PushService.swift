import Foundation
@preconcurrency import FirebaseMessaging

struct PushService: Sendable {
    let userService: UserService
    let messaging: Messaging

    init(userService: UserService, messaging: Messaging = .messaging()) {
        self.userService = userService
        self.messaging = messaging
    }

    func currentToken() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            messaging.token { token, error in
                if let error = error { continuation.resume(throwing: error); return }
                continuation.resume(returning: token)
            }
        }
    }

    func registerCurrentToken(for uid: String) async throws {
        let token = try await currentToken()
        guard let token = token else { return }
        try await userService.setFcmToken(uid: uid, token: token)
    }

    func unregister(for uid: String) async {
        try? await userService.setFcmToken(uid: uid, token: nil)
    }

    func setApnsToken(_ token: Data) {
        messaging.apnsToken = token
    }
}
