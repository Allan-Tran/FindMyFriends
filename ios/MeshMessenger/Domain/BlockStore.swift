import Foundation

/// Persists the set of usernames the local user has blocked.
/// Blocking is purely local — filtered at the view layer only.
@MainActor
final class BlockStore: ObservableObject {
    @Published private(set) var blockedUsernames: Set<String> = []

    private static let udKey = "mesh.blockedUsernames"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.udKey) ?? []
        blockedUsernames = Set(stored)
    }

    func block(_ username: String) {
        guard !username.isEmpty else { return }
        blockedUsernames.insert(username)
        persist()
    }

    func unblock(_ username: String) {
        blockedUsernames.remove(username)
        persist()
    }

    func isBlocked(_ username: String) -> Bool {
        blockedUsernames.contains(username)
    }

    private func persist() {
        UserDefaults.standard.set(Array(blockedUsernames), forKey: Self.udKey)
    }
}
