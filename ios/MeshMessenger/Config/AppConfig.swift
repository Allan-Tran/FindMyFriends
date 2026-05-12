import Foundation

enum AppConfig {
    /// When true, the iOS app talks to a local Firebase emulator suite instead of the
    /// live project. The emulator must be running (`firebase emulators:start` in
    /// firebase/). Set the host to whatever address your dev machine has on the LAN
    /// the iPhone/simulator can reach. Simulator on the same Mac can use "localhost".
    static let useEmulator: Bool = false
    static let emulatorHost: String = "localhost"

    static let multipeerServiceType = "mesh-msgr"

    static let proximityServiceUUID = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    static let proximityIdentityCharacteristicUUID = "B1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    static let defaultMessageTTL: Int = 5
    static let seenCacheCapacity: Int = 1024
    static let seenCacheTTL: TimeInterval = 60 * 30

    static let lateMessageThreshold: TimeInterval = 30
}
