import Foundation
import UIKit
import UserNotifications
import Combine

@MainActor
final class PushNotificationCenter: NSObject, ObservableObject {
    @Published private(set) var deviceToken: String?

    private let pushAPI: PushAPI
    private weak var router: MessageRouter?

    init(client: APIClient) {
        self.pushAPI = PushAPI(client: client)
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(router: MessageRouter) {
        self.router = router
    }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
            }
        } catch { }
    }

    func handleDeviceToken(_ raw: Data) async {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = hex
        try? await pushAPI.register(deviceToken: hex)
    }

    func handleRegistrationFailure(_ error: Error) {
        self.deviceToken = nil
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let router = router else { return .noData }
        let ids = router.activeGroupIds
        await router.syncEngine.fetchOnce(groupIds: ids)
        return .newData
    }

    func unregister() async {
        guard let token = deviceToken else { return }
        try? await pushAPI.unregister(deviceToken: token)
        self.deviceToken = nil
    }
}

extension PushNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
