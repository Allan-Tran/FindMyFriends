import Foundation

enum ProximityBand: String, Codable, Sendable, CaseIterable {
    case rightHere
    case nearby
    case close
    case far
    case outOfRange

    var label: String {
        switch self {
        case .rightHere: return "Right here"
        case .nearby: return "Nearby"
        case .close: return "Close"
        case .far: return "Far"
        case .outOfRange: return "Out of range"
        }
    }

    static func fromEstimatedMeters(_ meters: Double?) -> ProximityBand {
        guard let m = meters else { return .outOfRange }
        switch m {
        case ..<5: return .rightHere
        case 5..<20: return .nearby
        case 20..<50: return .close
        default: return .far
        }
    }
}
