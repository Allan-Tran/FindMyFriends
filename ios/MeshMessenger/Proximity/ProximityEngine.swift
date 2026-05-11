import Foundation
import CoreBluetooth

struct NearbyPeerProximity: Identifiable, Sendable {
    let id: String
    var username: String?
    var smoothedRssi: Double
    var estimatedMeters: Double
    var band: ProximityBand
    var lastSeenAt: Date
}

@MainActor
final class ProximityEngine: NSObject, ObservableObject {
    @Published private(set) var peers: [NearbyPeerProximity] = []
    @Published private(set) var isRunning: Bool = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var filters: [String: KalmanFilter] = [:]
    private var lastSeen: [String: Date] = [:]
    private var usernames: [String: String] = [:]
    private var identityValueLocal: Data = Data()

    private let serviceUUID = CBUUID(string: AppConfig.proximityServiceUUID)
    private let identityCharacteristicUUID = CBUUID(string: AppConfig.proximityIdentityCharacteristicUUID)

    private static let staleThreshold: TimeInterval = 15

    func start(localIdentity: String) {
        guard !isRunning else { return }
        identityValueLocal = localIdentity.data(using: .utf8) ?? Data()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        peripheral = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        isRunning = true
    }

    func stop() {
        central?.stopScan()
        central = nil
        if let p = peripheral, p.isAdvertising { p.stopAdvertising() }
        peripheral?.removeAllServices()
        peripheral = nil
        filters.removeAll()
        lastSeen.removeAll()
        peers = []
        isRunning = false
    }

    func attachUsername(_ username: String, to peerKey: String) {
        usernames[peerKey] = username
        rebuildPeers()
    }

    private func ingest(rssi: Int, for key: String) {
        let measurement = Double(rssi)
        if filters[key] == nil {
            filters[key] = KalmanFilter(initial: measurement)
        }
        let smoothed = filters[key]!.update(measurement)
        lastSeen[key] = Date()
        let meters = RSSIDistance.meters(fromRssi: smoothed)
        let band = ProximityBand.fromEstimatedMeters(meters)
        upsertPeer(key: key, smoothedRssi: smoothed, estimatedMeters: meters, band: band)
    }

    private func upsertPeer(key: String, smoothedRssi: Double, estimatedMeters: Double, band: ProximityBand) {
        let username = usernames[key]
        let now = Date()
        if let idx = peers.firstIndex(where: { $0.id == key }) {
            peers[idx].smoothedRssi = smoothedRssi
            peers[idx].estimatedMeters = estimatedMeters
            peers[idx].band = band
            peers[idx].lastSeenAt = now
            peers[idx].username = username ?? peers[idx].username
        } else {
            peers.append(NearbyPeerProximity(id: key, username: username, smoothedRssi: smoothedRssi, estimatedMeters: estimatedMeters, band: band, lastSeenAt: now))
        }
        pruneStale()
    }

    private func rebuildPeers() {
        for i in peers.indices {
            if let u = usernames[peers[i].id] { peers[i].username = u }
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-Self.staleThreshold)
        peers.removeAll { $0.lastSeenAt < cutoff }
    }
}

extension ProximityEngine: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: [self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let key = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        Task { @MainActor in
            self.ingest(rssi: rssi, for: key)
        }
    }
}

extension ProximityEngine: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            guard peripheral.state == .poweredOn else { return }
            let characteristic = CBMutableCharacteristic(
                type: self.identityCharacteristicUUID,
                properties: [.read],
                value: self.identityValueLocal,
                permissions: [.readable]
            )
            let service = CBMutableService(type: self.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            peripheral.add(service)
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [self.serviceUUID],
                CBAdvertisementDataLocalNameKey: "mesh"
            ])
        }
    }
}
