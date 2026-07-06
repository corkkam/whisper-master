import CoreBluetooth
import Foundation

// MARK: - ProximityBeacon
//
// Advertises this Mac as a Bluetooth-LE beacon (mesh service UUID + a short
// token) so other Macs can estimate how physically close we are from the signal
// strength they observe. Best-effort: if Bluetooth is off or unauthorized, it
// simply doesn't advertise and proximity stays unknown.

final class ProximityBeacon: NSObject, @unchecked Sendable {
    private var manager: CBPeripheralManager?
    private let queue = DispatchQueue(label: "app.whispermaster.mesh.beacon")
    private let token: String

    init(token: String) {
        self.token = token
        super.init()
    }

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func stop() {
        manager?.stopAdvertising()
        manager = nil
    }
}

extension ProximityBeacon: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [MeshBluetooth.serviceUUID],
            CBAdvertisementDataLocalNameKey: token,
        ])
    }
}
