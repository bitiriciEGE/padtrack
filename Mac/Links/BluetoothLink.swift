import Foundation
import CoreBluetooth
import PadTrackCore

enum PadTrackBLE {
    static let service = CBUUID(string: PadTrackProtocol.bleServiceUUID)
    static let frame = CBUUID(string: PadTrackProtocol.bleFrameCharacteristicUUID)
    static let control = CBUUID(string: PadTrackProtocol.bleControlCharacteristicUUID)
}

/// Scans for iPads advertising the PadTrack service and owns the central manager.
/// Delegate callbacks arrive on the core queue.
final class BLEDiscovery: NSObject, CBCentralManagerDelegate {
    struct Device: Equatable {
        let id: UUID
        let name: String
    }

    var onChange: (([Device]) -> Void)?

    private let queue: DispatchQueue
    private var central: CBCentralManager?
    private var seen: [UUID: (peripheral: CBPeripheral, name: String, lastSeen: TimeInterval)] = [:]
    private var links: [UUID: BLELink] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Advertisements stop arriving when an iPad leaves; forget it after a while.
    func pruneStale(now: TimeInterval) {
        let before = seen.count
        seen = seen.filter { id, entry in links[id] != nil || now - entry.lastSeen < 10 }
        if seen.count != before { publish() }
    }

    func makeLink(for id: UUID) -> BLELink? {
        guard let central, let entry = seen[id] else { return nil }
        links[id]?.close()
        let link = BLELink(central: central, peripheral: entry.peripheral, owner: self)
        links[id] = link
        return link
    }

    func linkFinished(_ id: UUID) {
        links[id] = nil
    }

    private func publish() {
        let devices = seen.map { Device(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
        onChange?(devices)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [PadTrackBLE.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            seen.removeAll()
            publish()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "iPad"
        let isNew = seen[peripheral.identifier] == nil
        seen[peripheral.identifier] = (peripheral, name, ProcessInfo.processInfo.systemUptime)
        if isNew { publish() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.fail("Bluetooth bağlantısı kurulamadı")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.fail("Bluetooth bağlantısı koptu")
    }
}

final class BLELink: NSObject, TrackpadLink, CBPeripheralDelegate {
    var onMessage: ((Message) -> Void)?
    var onClose: ((String) -> Void)?

    private let central: CBCentralManager
    private let peripheral: CBPeripheral
    private weak var owner: BLEDiscovery?
    private var control: CBCharacteristic?
    private var notifying = false
    private var closed = false

    init(central: CBCentralManager, peripheral: CBPeripheral, owner: BLEDiscovery) {
        self.central = central
        self.peripheral = peripheral
        self.owner = owner
        super.init()
    }

    func start() {
        central.connect(peripheral, options: nil)
    }

    func didConnect() {
        guard !closed else { return }
        peripheral.delegate = self
        peripheral.discoverServices([PadTrackBLE.service])
    }

    func send(_ message: Message) {
        guard !closed, notifying, let control else { return }
        peripheral.writeValue(message.encoded(), for: control, type: .withoutResponse)
    }

    func close() {
        guard !closed else { return }
        closed = true
        central.cancelPeripheralConnection(peripheral)
        owner?.linkFinished(peripheral.identifier)
    }

    func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        central.cancelPeripheralConnection(peripheral)
        owner?.linkFinished(peripheral.identifier)
        onClose?(reason)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PadTrackBLE.service }) else {
            fail("iPad'de PadTrack servisi bulunamadı")
            return
        }
        peripheral.discoverCharacteristics([PadTrackBLE.frame, PadTrackBLE.control], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == PadTrackBLE.frame {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == PadTrackBLE.control {
                control = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == PadTrackBLE.frame {
            notifying = characteristic.isNotifying
            // The core keeps re-sending `subscribe` until the iPad answers with `hello`.
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closed, characteristic.uuid == PadTrackBLE.frame,
              let data = characteristic.value,
              let message = try? Message.decode(data) else { return }
        onMessage?(message)
    }
}
