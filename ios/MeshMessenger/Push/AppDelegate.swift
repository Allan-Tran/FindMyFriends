import UIKit
import FirebaseCore
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pushCenter: PushNotificationCenter?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseManager.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.pushCenter?.handleApnsToken(deviceToken)
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[Push] APNs registration failed: \(error)")
        #endif
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await Self.pushCenter?.handleRemoteNotification(userInfo) ?? .noData
    }
}
