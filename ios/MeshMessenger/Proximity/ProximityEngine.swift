import Foundation
@preconcurrency import CoreBluetooth
import UIKit
import os.log

private let bleLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeshMessenger", category: "ProximityEngine")

private extension CBManagerState {
    var debugDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unhandled(\(rawValue))"
        }
    }
}

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
    private var pendingConnections: [String: CBPeripheral] = [:]
    private var rssiTimerTask: Task<Void, Never>?

    private let serviceUUID = CBUUID(string: AppConfig.proximityServiceUUID)
    private let identityCharacteristicUUID = CBUUID(string: AppConfig.proximityIdentityCharacteristicUUID)
    private let messageCharacteristicUUID = CBUUID(string: AppConfig.proximityMessageCharacteristicUUID)

    private static let staleThreshold: TimeInterval = 30
    
    func writeToAllConnectedPeripherals(_ data: Data) {
        for peripheral in connectedPeripherals.values {
            writeMessageData(data, to: peripheral)
        }
    }

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
        startRSSIPolling()
    }

    func stop() {
        isRunning = false   // set first so async callbacks skip reconnect logic
        rssiTimerTask?.cancel()
        rssiTimerTask = nil
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
        pendingConnections.removeAll()
        peers = []
    }

    func attachUsername(_ username: String, to peerKey: String) {
        usernames[peerKey] = username
        rebuildPeers()
    }

    func writeMessageData(_ data: Data, to peripheral: CBPeripheral) {
        guard peripheral.state == .connected, let services = peripheral.services else { return }
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

    private func startRSSIPolling() {
        rssiTimerTask?.cancel()
        bleLog.info("[rssi] polling loop started")
        rssiTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    let count = self.connectedPeripherals.count
                    bleLog.info("[rssi] polling \(count, privacy: .public) connected peripheral(s)")
                    for (key, peripheral) in self.connectedPeripherals {
                        guard peripheral.state == .connected else {
                            bleLog.debug("[rssi] skip readRSSI — \(key, privacy: .public) not connected (state=\(peripheral.state.rawValue, privacy: .public))")
                            continue
                        }
                        bleLog.debug("[rssi] readRSSI → \(key, privacy: .public)")
                        peripheral.readRSSI()
                    }
                }
            }
            bleLog.info("[rssi] polling loop ended (task cancelled)")
        }
    }

    private func buildAndAdvertise() {
        guard let peripheral, peripheral.state == .poweredOn else {
            bleLog.warning("[peripheral] buildAndAdvertise skipped — manager not ready (state=\(self.peripheral?.state.rawValue ?? -1, privacy: .public))")
            return
        }
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
        let stale = peers.filter { $0.lastSeenAt < cutoff }
        for p in stale {
            let age = Date().timeIntervalSince(p.lastSeenAt)
            bleLog.warning("[prune] 🗑 removing \(p.id, privacy: .public) (\(p.username ?? "?", privacy: .public)) — last seen \(String(format: "%.1f", age), privacy: .public)s ago")
        }
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
                switch p.state {
                case .connected:
                    self.connectedPeripherals[key] = p
                    if p.services == nil { p.discoverServices([self.serviceUUID]) }
                case .connecting:
                    // OS is still trying to connect — just track it; connect() not needed.
                    self.pendingConnections[key] = p
                default:
                    // .disconnected / .disconnecting: the OS dropped the request.
                    // Don't add to pendingConnections — let didDiscover handle a fresh connect.
                    break
                }
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            bleLog.info("[central] state changed → \(state.debugDescription, privacy: .public)")
            guard state == .poweredOn else { return }
            guard self.isRunning else {
                bleLog.info("[central] poweredOn but engine stopped — skipping scan")
                return
            }
            self.central?.scanForPeripherals(withServices: [self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            bleLog.info("[central] scan started")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let key = peripheral.identifier.uuidString
        let rssiValue = RSSI.intValue
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "?"

        Task { @MainActor in
            self.ingest(rssi: rssiValue, for: key)

            // Only start connecting if not already connected or connecting.
            // connectedPeripherals is populated in didConnect, not here, to
            // prevent commands being sent to a peripheral in .connecting state.
            let alreadyConnected = self.connectedPeripherals[key] != nil
            let alreadyPending   = self.pendingConnections[key] != nil

            if !alreadyConnected && !alreadyPending {
                peripheral.delegate = self
                self.pendingConnections[key] = peripheral // RETAINS THE OBJECT
                bleLog.info("[discover] 🔗 initiating connect to \(key, privacy: .public)")
                self.central?.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let key = peripheral.identifier.uuidString
        bleLog.info("[connect] ✅ connected to \(key, privacy: .public) — discovering services")
        Task { @MainActor in
            self.pendingConnections.removeValue(forKey: key)
            self.connectedPeripherals[key] = peripheral
            peripheral.discoverServices([self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        let desc = error.map { "\($0)" } ?? "nil"
        let code = (error as? CBError).map { "\($0.code.rawValue)" } ?? "?"
        bleLog.error("[connect] ❌ FAILED to connect \(key, privacy: .public) — code=\(code, privacy: .public) \(desc, privacy: .public)")
        Task { @MainActor in
            // Hard failure — clear both tracking sets so didDiscover can retry on next advertisement.
            self.pendingConnections.removeValue(forKey: key)
            self.connectedPeripherals.removeValue(forKey: key)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        if let error = error {
            let cbCode = (error as? CBError)?.code.rawValue
            let desc = "\(error)"
            bleLog.warning("[disconnect] ⚠️ \(key, privacy: .public) dropped — cbErrorCode=\(cbCode.map(String.init) ?? "?", privacy: .public) — \(desc, privacy: .public)")
        } else {
            bleLog.info("[disconnect] \(key, privacy: .public) gracefully disconnected (nil error — likely cancelPeripheralConnection)")
        }
        Task { @MainActor in
            self.connectedPeripherals.removeValue(forKey: key)
            // Don't reconnect if the engine was stopped while this task was queued.
            guard self.isRunning else { return }
            self.pendingConnections[key] = peripheral
            let options: [String: Any] = [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ]
            bleLog.info("[disconnect] 🔄 scheduling persistent reconnect for \(key, privacy: .public)")
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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let key = peripheral.identifier.uuidString
        if let error = error {
            let cbCode = (error as? CBError)?.code.rawValue
            bleLog.warning("[rssi] ❌ readRSSI failed for \(key, privacy: .public) — cbErrorCode=\(cbCode.map(String.init) ?? "?", privacy: .public) — \(error, privacy: .public)")
            return
        }
        let rssiValue = RSSI.intValue
        bleLog.debug("[rssi] ✅ \(key, privacy: .public) → \(rssiValue, privacy: .public) dBm")
        Task { @MainActor in
            self.ingest(rssi: rssiValue, for: key)
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
            if peripheral.isAdvertising {
                return  // already live — nothing to do
            }
            if self.messageCharacteristic != nil {
                // Services were restored by willRestoreState; don't tear them down
                // (that would drop existing central subscriptions). Just restart advertising.
                peripheral.startAdvertising([
                    CBAdvertisementDataServiceUUIDsKey: [self.serviceUUID],
                    CBAdvertisementDataLocalNameKey: self.localUsername
                ])
            } else {
                self.buildAndAdvertise()
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            bleLog.error("[peripheral] ❌ advertising FAILED: \(error, privacy: .public)")
        } else {
            bleLog.info("[peripheral] ✅ advertising started successfully")
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


