import Foundation
import Network
import Combine
import FirebaseFirestore

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isOnline: Bool = false

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.meshmessenger.sync.monitor")
    private let relayService: RelayService
    private weak var router: MessageRouter?

    private var listeners: [UUID: ListenerRegistration] = [:]
    private var lastSeen: [UUID: Date] = [:]

    init(relayService: RelayService = RelayService(), router: MessageRouter? = nil) {
        self.relayService = relayService
        self.router = router
        self.monitor = NWPathMonitor()
    }

    func attach(router: MessageRouter) {
        self.router = router
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor.cancel()
        for (_, listener) in listeners { listener.remove() }
        listeners.removeAll()
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

    /// Push an outgoing envelope to Firestore. Best-effort.
    func push(envelope: MeshMessage, senderUid: String) async {
        do {
            try await relayService.post(envelope: envelope, groupId: envelope.groupId.uuidString, senderUid: senderUid)
        } catch {
            // BLE mesh remains the primary path; ignore.
        }
    }

    /// One-shot fetch — used from background push handlers to catch up before sleeping.
    func fetchOnce(groupIds: Set<UUID>) async {
        for id in groupIds { await fetchOnce(groupId: id) }
    }

    private func fetchOnce(groupId: UUID) async {
        let since = lastSeen[groupId]
        do {
            let items = try await relayService.fetchOnce(groupId: groupId.uuidString, since: since)
            for item in items { ingest(item) }
        } catch {
            // ignore
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
