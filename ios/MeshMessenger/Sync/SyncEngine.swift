import Foundation
import Network
import Combine
import FirebaseFirestore

private struct OutboxItem {
    let envelope: MeshMessage
    let senderUid: String
}

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isOnline: Bool = false

    private var monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.meshmessenger.sync.monitor")
    private let relayService: RelayService
    private weak var router: MessageRouter?
    private var isMonitoring = false

    private var listeners: [UUID: ListenerRegistration] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private var outbox: [OutboxItem] = []

    init(relayService: RelayService = RelayService(), router: MessageRouter? = nil) {
        self.relayService = relayService
        self.router = router
        self.monitor = NWPathMonitor()
        beginMonitoring()
    }

    func attach(router: MessageRouter) {
        self.router = router
    }

    // Called from router.start() — idempotent; monitor may already be running from init.
    func start() {
        beginMonitoring()
    }

    func stop() {
        monitor.cancel()
        // Replace with a fresh instance so beginMonitoring() works after the next start().
        monitor = NWPathMonitor()
        isMonitoring = false
        isOnline = false
        for (_, listener) in listeners { listener.remove() }
        listeners.removeAll()
    }

    private func beginMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                if self.isOnline && wasOffline {
                    await self.flushOutbox()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Subscribe to the relay subcollection for each active group. Idempotent —
    /// drops listeners for groups no longer in the active set, and starts new ones
    /// for newly active ones.
    func updateActiveGroups(_ ids: Set<UUID>) {
        let current = Set(listeners.keys)
        for stale in current.subtracting(ids) {
            listeners.removeValue(forKey: stale)?.remove()
        }
        for newId in ids.subtracting(current) {
            startListener(for: newId)
        }
    }

    /// Push an outgoing envelope to Firestore. Queues for retry if offline or on failure.
    func push(envelope: MeshMessage, senderUid: String) async {
        guard isOnline else {
            outbox.append(OutboxItem(envelope: envelope, senderUid: senderUid))
            return
        }
        do {
            try await relayService.post(envelope: envelope, groupId: envelope.groupId.uuidString, senderUid: senderUid)
        } catch {
            outbox.append(OutboxItem(envelope: envelope, senderUid: senderUid))
        }
    }

    private func flushOutbox() async {
        guard !outbox.isEmpty else { return }
        let pending = outbox
        outbox.removeAll()
        for item in pending {
            do {
                try await relayService.post(envelope: item.envelope, groupId: item.envelope.groupId.uuidString, senderUid: item.senderUid)
            } catch {
                outbox.append(item)
            }
        }
    }

    /// One-shot fetch — returns total number of new envelopes ingested across all groups.
    func fetchOnce(groupIds: Set<UUID>) async -> Int {
        var total = 0
        for id in groupIds { total += await fetchOnce(groupId: id) }
        return total
    }

    private func fetchOnce(groupId: UUID) async -> Int {
        let since = lastSeen[groupId]
        do {
            let items = try await relayService.fetchOnce(groupId: groupId.uuidString, since: since)
            for item in items { ingest(item) }
            return items.count
        } catch {
            return 0
        }
    }

    private func startListener(for groupId: UUID) {
        let since = lastSeen[groupId]
        let listener = relayService.observeMessages(groupId: groupId.uuidString, since: since) { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.ingest(msg)
            }
        }
        listeners[groupId] = listener
    }

    private func ingest(_ msg: FirestoreRelayMessage) {
        guard let data = Data(base64Encoded: msg.envelopePayload),
              let envelope = try? MeshCodec.decoder.decode(MeshMessage.self, from: data) else { return }
        router?.ingest(envelope, source: .relay)
        if msg.storedAt.dateValue() > (lastSeen[envelope.groupId] ?? .distantPast) {
            lastSeen[envelope.groupId] = msg.storedAt.dateValue()
        }
    }
}
