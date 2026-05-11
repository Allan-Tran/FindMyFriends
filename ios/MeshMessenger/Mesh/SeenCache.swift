import Foundation

final class SeenCache: @unchecked Sendable {
    private struct Entry { let id: UUID; let seenAt: Date }
    private var entries: [UUID: Date] = [:]
    private var order: [UUID] = []
    private let capacity: Int
    private let ttl: TimeInterval
    private let lock = NSLock()

    init(capacity: Int = AppConfig.seenCacheCapacity, ttl: TimeInterval = AppConfig.seenCacheTTL) {
        self.capacity = capacity
        self.ttl = ttl
    }

    @discardableResult
    func insertIfNew(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        evictExpiredLocked()
        if let seenAt = entries[id], Date().timeIntervalSince(seenAt) < ttl {
            return false
        }
        entries[id] = Date()
        order.append(id)
        if order.count > capacity {
            let drop = order.removeFirst()
            entries.removeValue(forKey: drop)
        }
        return true
    }

    private func evictExpiredLocked() {
        let now = Date()
        while let first = order.first, let ts = entries[first], now.timeIntervalSince(ts) >= ttl {
            order.removeFirst()
            entries.removeValue(forKey: first)
        }
    }
}
