import Foundation
import CryptoKit

enum ContactHasher {
    // HMAC-SHA256 with a fixed app-level pepper, matching the server's PhoneNumberHasher.
    // The server uses HMAC-SHA256 keyed with the pepper from PhoneHashOptions.
    // Key must match appsettings.json → PhoneHash:Pepper.
    //
    // In production this should be fetched from a server-side /config endpoint.
    // For now the default matches the local development seed in appsettings.json.
    private static let pepper = "CHANGE_ME_BEFORE_SHIP"

    static func hash(_ e164: String) -> String {
        let key = SymmetricKey(data: Data(pepper.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(e164.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func hashAll(_ numbers: [String]) -> [String] {
        numbers.map { hash(normalize($0)) }
    }

    // Strip everything except digits and leading +.
    private static func normalize(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch == "+" && out.isEmpty { out.append(ch) }
            else if ch.isNumber { out.append(ch) }
        }
        return out
    }
}
