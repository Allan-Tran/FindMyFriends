import Foundation

enum AppConfig {
    /// Set to true to point Auth, Firestore, and Storage at the local emulator
    /// suite. Run `firebase emulators:start` in firebase/ first.
    /// Simulator uses "localhost"; a physical device needs your Mac's LAN IP.
    #if DEBUG
    static let useEmulator: Bool = true
    static let emulatorHost: String = "127.0.0.1"
    #else
    static let useEmulator: Bool = false
    static let emulatorHost: String = ""
    #endif

    static let multipeerServiceType = "mesh-msgr"

    static let proximityServiceUUID = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    static let proximityIdentityCharacteristicUUID = "B1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    static let proximityMessageCharacteristicUUID = "C1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    static let defaultMessageTTL: Int = 5
    static let seenCacheCapacity: Int = 1024
    static let seenCacheTTL: TimeInterval = 60 * 30

    static let lateMessageThreshold: TimeInterval = 30
}
