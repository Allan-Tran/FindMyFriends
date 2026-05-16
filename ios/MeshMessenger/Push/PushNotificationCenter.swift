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
    private weak var dmStore: DMStore?

    init(pushService: PushService = PushService(userService: UserService())) {
        self.pushService = pushService
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    func attach(session: AuthSession, router: MessageRouter, dmStore: DMStore) {
        self.session = session
        self.router = router
        self.dmStore = dmStore
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
        let kind = userInfo["kind"] as? String
        if kind == "dm-relay",
           let dmIdStr = userInfo["dmId"] as? String,
           let dmId = UUID(uuidString: dmIdStr) {
            guard let store = dmStore else { return .noData }
            await store.handleIncomingDMPush(dmId: dmId)
            return .newData
        }
        guard let router = router else { return .noData }
        let fetched = await router.syncEngine.fetchOnce(groupIds: router.activeGroupIds)
        await dmStore?.fetchAll()
        return fetched > 0 ? .newData : .noData
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
