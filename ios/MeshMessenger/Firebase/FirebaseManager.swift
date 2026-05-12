import Foundation
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

enum FirebaseManager {
    static func configure() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        if AppConfig.useEmulator {
            wireEmulator()
        }
    }

    private static func wireEmulator() {
        let host = AppConfig.emulatorHost
        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings

        Auth.auth().useEmulator(withHost: host, port: 9099)
    }
}
