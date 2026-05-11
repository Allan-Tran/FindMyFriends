import Foundation

enum AppConfig {
    static let backendBaseURL: URL = URL(string: "http://localhost:5080")!

    static let multipeerServiceType = "mesh-msgr"

    static let proximityServiceUUID = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    static let proximityIdentityCharacteristicUUID = "B1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    static let defaultMessageTTL: Int = 5
    static let seenCacheCapacity: Int = 1024
    static let seenCacheTTL: TimeInterval = 60 * 30

    static let lateMessageThreshold: TimeInterval = 30
}
