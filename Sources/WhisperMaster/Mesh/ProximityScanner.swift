import CoreBluetooth
import Foundation

// MARK: - ProximityScanner
//
// Scans for other Macs' proximity beacons and reports a coarse near/medium/far
// bucket per advertised token (derived from RSSI). Best-effort: no Bluetooth or
// authorization simply yields no updates.

final class ProximityScanner: NSObject, @unchecked Sendable {
    private var manager: CBCentralManager?
    private let queue = DispatchQueue(label: "app.whispermaster.mesh.scanner")
    private let onUpdate: @Sendable (_ token: String, _ proximity: MeshPeer.Proximity) -> Void

    init(onUpdate: @escaping @Sendable (String, MeshPeer.Proximity) -> Void) {
        self.onUpdate = onUpdate
        super.init()
    }

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    func stop() {
        manager?.stopScan()
        manager = nil
    }
}

extension ProximityScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Allow duplicates so RSSI (and thus proximity) keeps refreshing.
        central.scanForPeripherals(
            withServices: [MeshBluetooth.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let token = advertisementData[CBAdvertisementDataLocalNameKey] as? String else { return }
        onUpdate(token, MeshBluetooth.proximity(forRSSI: RSSI.intValue))
    }
}
