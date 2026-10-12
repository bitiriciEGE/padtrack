import Foundation
import CoreBluetooth
import PadTrackCore

/// Bluetooth LE fallback. The iPad advertises a GATT service; the Mac subscribes to the
/// frame characteristic (notifications, iPad -> Mac) and writes to the control
/// characteristic (Mac -> iPad). Latency is higher than USB/Wi‑Fi because BLE only talks
/// once per connection interval (15 ms or more), but it works with no network at all.
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate {
    var onMessage: ((Message, PeerLink) -> Void)?
    var onClose: ((PeerLink) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue: DispatchQueue
    private let localName: String
    private var manager: CBPeripheralManager?
    private var links: [UUID: BLEPeerLink] = [:]

    private let serviceUUID = CBUUID(string: PadTrackProtocol.bleServiceUUID)
    private let frameCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: PadTrackProtocol.bleFrameCharacteristicUUID),
        properties: [.notify],
        value: nil,
        permissions: [.readable]
    )
    private let controlCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: PadTrackProtocol.bleControlCharacteristicUUID),
        properties: [.write, .writeWithoutResponse],
        value: nil,
        permissions: [.writeable]
    )

    init(queue: DispatchQueue, localName: String) {
        self.queue = queue
        self.localName = localName
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
        onStatus?("Başlatılıyor…")
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil
        let closing = Array(links.values)
        links.removeAll()
        for link in closing { onClose?(link) }
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [frameCharacteristic, controlCharacteristic]
            peripheral.removeAllServices()
            peripheral.add(service)
        case .poweredOff:
            onStatus?("Bluetooth kapalı")
        case .unauthorized:
            onStatus?("İzin yok (Ayarlar › PadTrack › Bluetooth)")
        case .unsupported:
            onStatus?("Bu cihaz desteklemiyor")
        default:
            onStatus?("Hazırlanıyor…")
        }
        if peripheral.state != .poweredOn {
            let closing = Array(links.values)
            links.removeAll()
            for link in closing { onClose?(link) }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onStatus?("Servis eklenemedi: \(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: localName,
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onStatus?("Yayın hatası: \(error.localizedDescription)")
        } else {
            onStatus?("Hazır")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == frameCharacteristic.uuid else { return }
        // Ask for the shortest connection interval the system allows.
        peripheral.setDesiredConnectionLatency(.low, for: central)
        _ = link(for: central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == frameCharacteristic.uuid,
              let link = links.removeValue(forKey: central.identifier) else { return }
        onClose?(link)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == controlCharacteristic.uuid {
            guard let value = request.value, let message = try? Message.decode(value) else { continue }
            onMessage?(message, link(for: request.central))
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for link in links.values { link.flush() }
    }

    private func link(for central: CBCentral) -> BLEPeerLink {
        if let existing = links[central.identifier] { return existing }
        let created = BLEPeerLink(manager: manager, characteristic: frameCharacteristic, central: central)
        links[central.identifier] = created
        return created
    }
}

final class BLEPeerLink: PeerLink {
    private weak var manager: CBPeripheralManager?
    private let characteristic: CBMutableCharacteristic
    private let central: CBCentral
    private var outbox: [(data: Data, structural: Bool)] = []

    init(manager: CBPeripheralManager?, characteristic: CBMutableCharacteristic, central: CBCentral) {
        self.manager = manager
        self.characteristic = characteristic
        self.central = central
    }

    func send(_ payload: Data, structural: Bool) {
        guard payload.count <= central.maximumUpdateValueLength else { return }
        if !structural, let last = outbox.last, !last.structural {
            // Only the newest move matters; replace the waiting one instead of queueing.
            outbox[outbox.count - 1] = (payload, false)
        } else {
            outbox.append((payload, structural))
        }
        if outbox.count > 64 { outbox.removeFirst(outbox.count - 64) }
        flush()
    }

    /// Sends as much as the Bluetooth stack accepts; the rest waits for `peripheralManagerIsReady`.
    func flush() {
        guard let manager else { return }
        while let next = outbox.first {
            guard manager.updateValue(next.data, for: characteristic, onSubscribedCentrals: [central]) else { return }
            outbox.removeFirst()
        }
    }

    /// A peripheral cannot hang up on a central; the Mac disconnects after receiving `bye`.
    func close() {
        outbox.removeAll()
    }
}
