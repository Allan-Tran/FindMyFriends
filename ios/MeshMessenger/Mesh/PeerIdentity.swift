import Foundation
import MultipeerConnectivity

enum PeerIdentity {
    private static let userDefaultsKey = "com.meshmessenger.mcpeerid"

    static func peerID(for displayName: String) -> MCPeerID {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let cached = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           cached.displayName == displayName {
            return cached
        }
        let fresh = MCPeerID(displayName: displayName)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        return fresh
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

extension UUID {
    var meshPrefix: String { String(uuidString.prefix(8)).lowercased() }
}
