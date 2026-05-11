import Foundation

enum DeliveryStatus: String, Codable, Sendable {
    case pending
    case sent
    case delivered
    case failed
}
