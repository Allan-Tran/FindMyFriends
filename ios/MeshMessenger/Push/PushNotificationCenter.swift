import Foundation
import UIKit
import UserNotifications
import Combine
import FirebaseMessaging

@MainActor
final class PushNotificationCenter: NSObject, ObservableObject {
    @Published private(set) var fcmToken: String?

    private let pushService: PushService
    private weak var session: AuthSession?
    private weak var router: MessageRouter?

    init(pushService: PushService = PushService(userService: UserService())) {
        self.pushService = pushService
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    func attach(session: AuthSession, router: MessageRouter) {
        self.session = session
        self.router = router
    }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            #if DEBUG
            print("[Push] authorization error: \(error)")
            #endif
        }
    }

    func handleApnsToken(_ raw: Data) {
        pushService.setApnsToken(raw)
    }

    func handleFcmToken(_ token: String?) async {
        self.fcmToken = token
        guard let token = token, let uid = session?.currentUid else { return }
        try? await pushService.userService.setFcmToken(uid: uid, token: token)
    }

    /// Called from AppDelegate on silent background notifications.
    /// The Cloud Function sends `{groupId, messageId, kind:"relay"}` — we fetch and persist.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let router = router else { return .noData }
        let ids = router.activeGroupIds
        await router.syncEngine.fetchOnce(groupIds: ids)
        return .newData
    }

    func unregister() async {
        guard let uid = session?.currentUid else { return }
        await pushService.unregister(for: uid)
        self.fcmToken = nil
    }
}

extension PushNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension PushNotificationCenter: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in await self.handleFcmToken(fcmToken) }
    }
}
