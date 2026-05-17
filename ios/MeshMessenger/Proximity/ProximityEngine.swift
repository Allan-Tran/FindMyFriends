import Foundation
@preconcurrency import CoreBluetooth
import UIKit

@MainActor
protocol ProximityEngineDelegate: AnyObject, Sendable {
    func proximityEngine(_ engine: ProximityEngine, didDiscoverUsername username: String, peripheral: CBPeripheral)
    func proximityEngine(_ engine: ProximityEngine, didReceiveMessageData data: Data)
}

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

    weak var delegate: ProximityEngineDelegate?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var messageCharacteristic: CBMutableCharacteristic?
    private var pendingBroadcast: Data?

    private var filters: [String: KalmanFilter] = [:]
    private var lastSeen: [String: Date] = [:]
    private var usernames: [String: String] = [:]
    private var identityValueLocal: Data = Data()
    private var localUsername: String = ""
    private var connectedPeripherals: [String: CBPeripheral] = [:]

    private let serviceUUID = CBUUID(string: AppConfig.proximityServiceUUID)
    private let identityCharacteristicUUID = CBUUID(string: AppConfig.proximityIdentityCharacteristicUUID)
    private let messageCharacteristicUUID = CBUUID(string: AppConfig.proximityMessageCharacteristicUUID)

    private static let staleThreshold: TimeInterval = 30

    func start(localIdentity: String) {
        localUsername = localIdentity
        identityValueLocal = localIdentity.data(using: .utf8) ?? Data()

        if isRunning {
            // Already running from state restoration — re-advertise with the correct identity.
            buildAndAdvertise()
            return
        }

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: false,
                CBCentralManagerOptionRestoreIdentifierKey: "com.meshmessenger.central"
            ]
        )
        peripheral = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false,
                CBPeripheralManagerOptionRestoreIdentifierKey: "com.meshmessenger.peripheral"
            ]
        )
        isRunning = true
    }

    func stop() {
        for (_, p) in connectedPeripherals { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        if let p = peripheral, p.isAdvertising { p.stopAdvertising() }
        peripheral?.removeAllServices()
        peripheral = nil
        messageCharacteristic = nil
        pendingBroadcast = nil
        filters.removeAll()
        lastSeen.removeAll()
        connectedPeripherals.removeAll()
        peers = []
        isRunning = false
    }

    func attachUsername(_ username: String, to peerKey: String) {
        usernames[peerKey] = username
        rebuildPeers()
    }

    func writeMessageData(_ data: Data, to peripheral: CBPeripheral) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == self.serviceUUID {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics where characteristic.uuid == self.messageCharacteristicUUID {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    // Push data to all centrals that subscribed to the message characteristic notification.
    // This is the background-safe broadcast path — works even when MCSession is suspended.
    func broadcastMessageData(_ data: Data) {
        guard let peripheral, let messageCharacteristic else { return }
        if !peripheral.updateValue(data, for: messageCharacteristic, onSubscribedCentrals: nil) {
            pendingBroadcast = data   // queue for retry when transmit queue drains
        }
    }

    // MARK: - Private helpers

    private func buildAndAdvertise() {
        guard let peripheral else { return }
        peripheral.removeAllServices()

        let identityCharacteristic = CBMutableCharacteristic(
            type: identityCharacteristicUUID,
            properties: [.read],
            value: identityValueLocal,
            permissions: [.readable]
        )

        let msgChar = CBMutableCharacteristic(
            type: messageCharacteristicUUID,
            properties: [.write, .read, .notify],
            value: nil,
            permissions: [.writeable, .readable]
        )
        messageCharacteristic = msgChar

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [identityCharacteristic, msgChar]
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: localUsername
        ])
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

// MARK: - CBCentralManagerDelegate

extension ProximityEngine: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        nonisolated(unsafe) let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            self.isRunning = true
            for p in restored {
                let key = p.identifier.uuidString
                p.delegate = self
                self.connectedPeripherals[key] = p
                if p.services == nil {
                    p.discoverServices([self.serviceUUID])
                }
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn else { return }
            central.scanForPeripherals(withServices: [self.serviceUUID], options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let key = peripheral.identifier.uuidString
        let rssiValue = RSSI.intValue

        Task { @MainActor in
            self.ingest(rssi: rssiValue, for: key)

            // Connect to any undiscovered peer regardless of whether we know their username —
            // we need the connection to stay alive for background message delivery.
            if self.connectedPeripherals[key] == nil {
                peripheral.delegate = self
                self.connectedPeripherals[key] = peripheral
                central.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        Task { @MainActor in
            // Hard failure (not a transient drop) — clear the slot so didDiscover
            // can try again when the peer is next seen.
            self.connectedPeripherals.removeValue(forKey: key)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        Task { @MainActor in
            // Keep the peripheral in connectedPeripherals so didDiscover doesn't open a
            // duplicate connection attempt while the persistent reconnect is in flight.
            self.connectedPeripherals[key] = peripheral
            let options: [String: Any] = [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ]
            self.central?.connect(peripheral, options: options)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ProximityEngine: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        Task { @MainActor in
            for service in services where service.uuid == self.serviceUUID {
                peripheral.discoverCharacteristics([self.identityCharacteristicUUID, self.messageCharacteristicUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        Task { @MainActor in
            for characteristic in characteristics {
                if characteristic.uuid == self.identityCharacteristicUUID {
                    peripheral.readValue(for: characteristic)
                } else if characteristic.uuid == self.messageCharacteristicUUID {
                    // Subscribe to notifications so the remote peripheral can push messages to us
                    // in the background without us having to poll.
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = peripheral.identifier.uuidString
        Task { @MainActor in
            if characteristic.uuid == self.identityCharacteristicUUID, let data = characteristic.value {
                if let resolvedUsername = String(data: data, encoding: .utf8) {
                    self.attachUsername(resolvedUsername, to: key)
                    self.delegate?.proximityEngine(self, didDiscoverUsername: resolvedUsername, peripheral: peripheral)
                    // Keep connection alive — do not disconnect after identity read.
                }
            } else if characteristic.uuid == self.messageCharacteristicUUID, let data = characteristic.value {
                self.delegate?.proximityEngine(self, didReceiveMessageData: data)
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension ProximityEngine: CBPeripheralManagerDelegate {
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        nonisolated(unsafe) let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        Task { @MainActor in
            self.isRunning = true
            // Recover the mutable characteristic reference so broadcastMessageData still works.
            for service in services where service.uuid == self.serviceUUID {
                for characteristic in service.characteristics ?? [] {
                    if let mutable = characteristic as? CBMutableCharacteristic,
                       mutable.uuid == self.messageCharacteristicUUID {
                        self.messageCharacteristic = mutable
                    }
                }
            }
        }
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            guard peripheral.state == .poweredOn else { return }
            // Skip setup if willRestoreState already gave us the characteristic —
            // removing services would break existing subscriptions from connected centrals.
            if self.messageCharacteristic == nil {
                self.buildAndAdvertise()
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            guard let data = self.pendingBroadcast, let char = self.messageCharacteristic else { return }
            if peripheral.updateValue(data, for: char, onSubscribedCentrals: nil) {
                self.pendingBroadcast = nil
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        let targetUUID = CBUUID(string: AppConfig.proximityMessageCharacteristicUUID)
        var collectedPayloads: [Data] = []

        for request in requests {
            if request.characteristic.uuid == targetUUID {
                if let data = request.value {
                    collectedPayloads.append(data)
                }
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }

        if !collectedPayloads.isEmpty {
            Task { @MainActor in
                for data in collectedPayloads {
                    self.delegate?.proximityEngine(self, didReceiveMessageData: data)
                }
            }
        }
    }
}
