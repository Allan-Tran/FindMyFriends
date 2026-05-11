import Foundation
import Network
import Combine

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isOnline: Bool = false

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.meshmessenger.sync.monitor")
    private let relayAPI: RelayAPI
    private weak var router: MessageRouter?

    private var lastFetchedAt: [UUID: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 20

    init(relayAPI: RelayAPI, router: MessageRouter? = nil) {
        self.relayAPI = relayAPI
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
                let newOnline = path.status == .satisfied
                if newOnline != self.isOnline {
                    self.isOnline = newOnline
                    if newOnline { self.beginPolling() }
                    else { self.endPolling() }
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor.cancel()
        endPolling()
    }

    func push(envelope: MeshMessage) async {
        guard isOnline else { return }
        do { _ = try await relayAPI.post(groupId: envelope.groupId, envelope: envelope) }
        catch { /* swallow; mesh remains primary */ }
    }

    func fetchOnce(groupIds: Set<UUID>) async {
        guard isOnline else { return }
        for groupId in groupIds {
            await fetch(groupId: groupId)
        }
    }

    private func fetch(groupId: UUID) async {
        let since = lastFetchedAt[groupId]
        do {
            let items = try await relayAPI.fetch(groupId: groupId, since: since)
            var maxStored: Date = since ?? Date(timeIntervalSince1970: 0)
            for item in items {
                guard let envelope = decodeEnvelope(item.envelopePayload) else { continue }
                router?.ingest(envelope, source: .relay)
                if item.storedAt > maxStored { maxStored = item.storedAt }
            }
            if !items.isEmpty { lastFetchedAt[groupId] = maxStored }
        } catch {
            /* ignore */
        }
    }

    private func decodeEnvelope(_ base64: String) -> MeshMessage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? MeshCodec.decoder.decode(MeshMessage.self, from: data)
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let ids = self.router?.activeGroupIds ?? []
                await self.fetchOnce(groupIds: ids)
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    private func endPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
