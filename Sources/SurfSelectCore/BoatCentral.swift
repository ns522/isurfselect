import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth central shared by the phone and the watch.
/// Callbacks arrive on the main queue, the same isolation as this class.
@MainActor
public final class BoatCentral: NSObject, ObservableObject {
    @Published public private(set) var status: BoatLinkStatus = .off
    @Published public private(set) var frame = SurfFrame()
    @Published public private(set) var song = ""

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var frameSubscribed = false
    private var songSubscribed = false
    private var running = false

    public override init() {
        super.init()
    }

    public func start() {
        running = true
        if central == nil {
            status = .scanning
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard peripheral == nil else { return }
        scanIfPoweredOn(showAsScanning: true)
    }

    public func stop() {
        running = false
        central?.stopScan()
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        clearLink()
        status = .off
    }

    public func send(_ command: BoatCommand) {
        guard let payload = SurfFrame.commandData(for: command) else { return }
        guard running, let peripheral, let commandCharacteristic else { return }
        self.frame = frame.applying(command)
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(payload, for: commandCharacteristic, type: writeType)
    }

    public func send(_ frame: SurfFrame) {
        guard running, let peripheral, let commandCharacteristic else { return }
        self.frame = frame
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(frame.linkData, for: commandCharacteristic, type: writeType)
    }

    private func scanIfPoweredOn(showAsScanning: Bool) {
        guard running, peripheral == nil, let central, central.state == .poweredOn else { return }
        if showAsScanning {
            status = .scanning
        }
        guard !central.isScanning else { return }
        central.scanForPeripherals(withServices: [BoatBluetooth.serviceUUID])
    }

    private func clearLink() {
        peripheral = nil
        commandCharacteristic = nil
        frameSubscribed = false
        songSubscribed = false
    }

    private func isSurfSelect(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if peripheral.name == BoatBluetooth.localName {
            return true
        }
        if advertisementData[CBAdvertisementDataLocalNameKey] as? String == BoatBluetooth.localName {
            return true
        }
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        if advertised.contains(BoatBluetooth.serviceUUID) || overflow.contains(BoatBluetooth.serviceUUID) {
            return true
        }
        // The scan is filtered to the boat service, so a hit with no parsed UUID list is still that service.
        return advertised.isEmpty && overflow.isEmpty
    }

    private func lostLink(_ message: String) {
        clearLink()
        guard running else { return }
        switch central?.state {
        case .poweredOff:
            status = .failed("Bluetooth is off")
        case .poweredOn:
            if case .failed = status {
                // Keep a more specific failure, then look for the boat again.
            } else {
                status = .failed(message)
            }
            scanIfPoweredOn(showAsScanning: false)
        default:
            status = .failed(message)
        }
    }
}

extension BoatCentral: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanIfPoweredOn(showAsScanning: true)
        case .poweredOff:
            central.stopScan()
            clearLink()
            if running {
                status = .failed("Bluetooth is off")
            }
        case .unauthorized:
            central.stopScan()
            clearLink()
            if running {
                status = .failed("Bluetooth unauthorized")
            }
        case .unsupported:
            central.stopScan()
            clearLink()
            if running {
                status = .failed("Bluetooth unsupported")
            }
        case .resetting, .unknown:
            if running, peripheral == nil {
                status = .scanning
            }
        @unknown default:
            if running {
                status = .failed("Bluetooth unavailable")
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard running, self.peripheral == nil, isSurfSelect(peripheral, advertisementData: advertisementData) else {
            return
        }
        central.stopScan()
        peripheral.delegate = self
        self.peripheral = peripheral
        status = .connecting
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running, self.peripheral == peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        status = .connecting
        peripheral.delegate = self
        peripheral.discoverServices([BoatBluetooth.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard running else { return }
        status = .failed("Connect failed")
        lostLink("Connect failed")
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        lostLink("Disconnected")
    }
}

extension BoatCentral: @MainActor CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard running, self.peripheral == peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BoatBluetooth.serviceUUID }) else {
            status = .failed("Discovery failed")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [BoatBluetooth.frameUUID, BoatBluetooth.commandUUID, BoatBluetooth.songUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard running, self.peripheral == peripheral else { return }
        let found = service.characteristics ?? []
        guard
            error == nil,
            let frameCharacteristic = found.first(where: { $0.uuid == BoatBluetooth.frameUUID }),
            let commandCharacteristic = found.first(where: { $0.uuid == BoatBluetooth.commandUUID }),
            let songCharacteristic = found.first(where: { $0.uuid == BoatBluetooth.songUUID })
        else {
            status = .failed("Discovery failed")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.commandCharacteristic = commandCharacteristic
        frameSubscribed = false
        songSubscribed = false
        peripheral.setNotifyValue(true, for: frameCharacteristic)
        peripheral.setNotifyValue(true, for: songCharacteristic)
        peripheral.readValue(for: frameCharacteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard running, self.peripheral == peripheral else { return }
        guard error == nil else {
            status = .failed("Subscribe failed")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard characteristic.isNotifying else { return }
        if characteristic.uuid == BoatBluetooth.frameUUID {
            frameSubscribed = true
        } else if characteristic.uuid == BoatBluetooth.songUUID {
            songSubscribed = true
        }
        if frameSubscribed && songSubscribed {
            status = .ready
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == BoatBluetooth.frameUUID {
            frame = value.count >= SurfFrame.length ? SurfFrame(bytes: value) : SurfFrame(linkBytes: value)
        } else if characteristic.uuid == BoatBluetooth.songUUID {
            guard let text = String(data: value, encoding: .utf8), !text.isEmpty else { return }
            song = text
        }
    }
}
