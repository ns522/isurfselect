import Combine
import CoreBluetooth
import Foundation

/// Fields the user has asked for that the bus has not confirmed yet.
private struct DisplayHold {
    var port: Bool?
    var speedTenths: Int?
    var volume: Int?
    var shape: Int?
    var shifting: Bool?
    var zones: [Int: Int] = [:]
    var until = Date.distantPast
}

/// CoreBluetooth central shared by the phone and the watch.
/// Callbacks arrive on the main queue, the same isolation as this class.
@MainActor
public final class BoatCentral: NSObject, ObservableObject {
    @Published public private(set) var status: BoatLinkStatus = .off
    @Published public private(set) var frame = SurfFrame()
    @Published public private(set) var song = ""
    @Published public private(set) var zones: [StereoZone] = []
    @Published public private(set) var firmwareAvailability: FirmwareAvailability = .unknown

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var zonesCharacteristic: CBCharacteristic?
    private var otaInfoCharacteristic: CBCharacteristic?
    private var otaControlCharacteristic: CBCharacteristic?
    private var otaDataCharacteristic: CBCharacteristic?
    private var frameSubscribed = false
    private var songSubscribed = false
    private var zonesSubscribed = false
    private var running = false
    private var outbound: [Data] = []
    private var outboundPump: Task<Void, Never>?
    /// Values the user just asked for. Bus echoes of the previous value are ignored until the boat catches up.
    private var displayHold = DisplayHold()
    private var installing = false
    private var installStop = false
    private var quietDisconnect = false
    private var firmwareEpoch = 0
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var writeTimeout: Task<Void, Never>?
    private var infoContinuation: CheckedContinuation<DeviceFirmwareInfo, Error>?
    private var infoPredicate: ((DeviceFirmwareInfo) -> Bool)?
    private var infoTimeout: Task<Void, Never>?

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
        guard running, peripheral != nil, commandCharacteristic != nil else { return }
        let updatedFrame = frame.applying(command)
        if updatedFrame != frame {
            self.frame = updatedFrame
        }
        switch command {
        case .zoneVolume(let id, let pct):
            if let index = zones.firstIndex(where: { $0.id == id }) {
                let clamped = min(max(pct, StereoZone.volumeRange.lowerBound), StereoZone.volumeRange.upperBound)
                if zones[index].volume != clamped {
                    zones[index].volume = clamped
                }
            }
        case .zoneStep(let id, let up):
            if let index = zones.firstIndex(where: { $0.id == id }) {
                let delta = up ? StereoZone.stepSize : -StereoZone.stepSize
                let clamped = min(
                    max(zones[index].volume + delta, StereoZone.volumeRange.lowerBound),
                    StereoZone.volumeRange.upperBound
                )
                if zones[index].volume != clamped {
                    zones[index].volume = clamped
                }
            }
        default:
            break
        }
        remember(command)
        enqueueOutbound(payload)
    }

    public func send(_ frame: SurfFrame) {
        guard running, peripheral != nil, commandCharacteristic != nil else { return }
        self.frame = frame
        enqueueOutbound(frame.linkData)
    }

    /// The screen updates immediately. Writes leave one at a time so a fast run of taps is not dropped by the radio.
    private func enqueueOutbound(_ payload: Data) {
        outbound.append(payload)
        guard outboundPump == nil else { return }
        outboundPump = Task { @MainActor in
            while !self.outbound.isEmpty {
                guard self.running, let peripheral = self.peripheral, let characteristic = self.commandCharacteristic else {
                    self.outbound.removeAll()
                    break
                }
                let payload = self.outbound.removeFirst()
                let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
                    ? .withoutResponse
                    : .withResponse
                peripheral.writeValue(payload, for: characteristic, type: writeType)
                if !self.outbound.isEmpty {
                    // Long enough for the bridge to finish one command before the next write replaces it.
                    try? await Task.sleep(nanoseconds: 950_000_000)
                }
            }
            self.outboundPump = nil
        }
    }

    /// Keeps the number the user just set on screen. The bus keeps announcing the old value until the boat accepts the command.
    private func remember(_ command: BoatCommand) {
        displayHold.until = Date().addingTimeInterval(2.0 + Double(outbound.count) * 1.0)
        switch command {
        case .side(let port):
            displayHold.port = port
        case .speed(let tenths):
            displayHold.speedTenths = tenths
        case .volume(let volume):
            displayHold.volume = volume
        case .shape(let shape):
            displayHold.shape = shape
        case .ballast:
            displayHold.shifting = true
        case .stopBallast:
            displayHold.shifting = false
        case .zoneVolume(let id, let percent):
            displayHold.zones[id] = min(
                max(percent, StereoZone.volumeRange.lowerBound),
                StereoZone.volumeRange.upperBound
            )
        case .zoneStep(let id, _):
            if let zone = zones.first(where: { $0.id == id }) {
                displayHold.zones[id] = zone.volume
            }
        case .leaveWater, .track, .refreshZones:
            break
        }
    }

    private func held(_ bus: SurfFrame) -> SurfFrame {
        guard displayHold.until > Date() else {
            displayHold.port = nil
            displayHold.speedTenths = nil
            displayHold.volume = nil
            displayHold.shape = nil
            displayHold.shifting = nil
            return bus
        }
        var shown = bus
        if let port = displayHold.port {
            if bus.port == port { displayHold.port = nil } else { shown.port = port }
        }
        if let speed = displayHold.speedTenths {
            if bus.speedTenths == speed { displayHold.speedTenths = nil } else { shown.speedTenths = speed }
        }
        if let volume = displayHold.volume {
            if bus.volume == volume { displayHold.volume = nil } else { shown.volume = volume }
        }
        if let shape = displayHold.shape {
            if bus.shape == shape { displayHold.shape = nil } else { shown.shape = shape }
        }
        if let shifting = displayHold.shifting {
            if bus.shifting == shifting { displayHold.shifting = nil } else { shown.shifting = shifting }
        }
        return shown
    }

    private func held(_ reported: [StereoZone]) -> [StereoZone] {
        guard displayHold.until > Date() else {
            displayHold.zones.removeAll()
            return reported
        }
        var shown = reported
        for index in shown.indices {
            let id = shown[index].id
            guard let wanted = displayHold.zones[id] else { continue }
            if shown[index].volume == wanted {
                displayHold.zones[id] = nil
            } else {
                shown[index].volume = wanted
            }
        }
        return shown
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
        zonesCharacteristic = nil
        otaInfoCharacteristic = nil
        otaControlCharacteristic = nil
        otaDataCharacteristic = nil
        frameSubscribed = false
        songSubscribed = false
        zonesSubscribed = false
        zones = []
        outbound.removeAll()
        outboundPump?.cancel()
        outboundPump = nil
        displayHold = DisplayHold()
        firmwareAvailability = .unknown
        firmwareEpoch += 1
    }

    private func isISurfSelect(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
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
        let quiet = quietDisconnect
        quietDisconnect = false
        failFirmwareWaiters(FirmwareUpdateError.disconnected)
        clearLink()
        guard running else { return }
        if quiet {
            status = .scanning
            scanIfPoweredOn(showAsScanning: true)
            return
        }
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
        guard running, self.peripheral == nil, isISurfSelect(peripheral, advertisementData: advertisementData) else {
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
        peripheral.discoverServices([BoatBluetooth.serviceUUID, BoatBluetooth.otaServiceUUID])
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
        if let ota = peripheral.services?.first(where: { $0.uuid == BoatBluetooth.otaServiceUUID }) {
            peripheral.discoverCharacteristics(
                [BoatBluetooth.otaInfoUUID, BoatBluetooth.otaControlUUID, BoatBluetooth.otaDataUUID],
                for: ota
            )
        } else {
            firmwareAvailability = .unsupported
        }
        peripheral.discoverCharacteristics(
            [BoatBluetooth.frameUUID, BoatBluetooth.commandUUID, BoatBluetooth.songUUID, BoatBluetooth.zonesUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard running, self.peripheral == peripheral else { return }
        if service.uuid == BoatBluetooth.otaServiceUUID {
            adoptFirmware(service, error: error)
            return
        }
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
        self.zonesCharacteristic = found.first(where: { $0.uuid == BoatBluetooth.zonesUUID })
        frameSubscribed = false
        songSubscribed = false
        zonesSubscribed = false
        peripheral.setNotifyValue(true, for: frameCharacteristic)
        peripheral.setNotifyValue(true, for: songCharacteristic)
        peripheral.readValue(for: frameCharacteristic)
        if let zonesCharacteristic {
            peripheral.setNotifyValue(true, for: zonesCharacteristic)
            peripheral.readValue(for: zonesCharacteristic)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard running, self.peripheral == peripheral else { return }
        if characteristic.uuid == BoatBluetooth.otaInfoUUID {
            return
        }
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
        } else if characteristic.uuid == BoatBluetooth.zonesUUID {
            zonesSubscribed = true
        }
        let hasZonesChar = zonesCharacteristic != nil
        if status != .ready, frameSubscribed && songSubscribed && (!hasZonesChar || zonesSubscribed) {
            status = .ready
            if hasZonesChar {
                send(.refreshZones)
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == BoatBluetooth.otaInfoUUID {
            if let info = FirmwareProtocol.decodeInfo(value) {
                noteFirmware(info)
            } else if case .unknown = firmwareAvailability {
                firmwareAvailability = .unsupported
            }
            return
        }
        if characteristic.uuid == BoatBluetooth.frameUUID {
            let bus = value.count >= SurfFrame.length ? SurfFrame(bytes: value) : SurfFrame(linkBytes: value)
            let shown = held(bus)
            if frame != shown {
                frame = shown
            }
        } else if characteristic.uuid == BoatBluetooth.songUUID {
            guard let text = String(data: value, encoding: .utf8), !text.isEmpty else { return }
            song = text
        } else if characteristic.uuid == BoatBluetooth.zonesUUID {
            if let decoded = StereoZone.decodeZones(value) {
                let shown = held(decoded)
                if zones != shown {
                    zones = shown
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BoatBluetooth.otaControlUUID || characteristic.uuid == BoatBluetooth.otaDataUUID else {
            return
        }
        writeTimeout?.cancel()
        writeTimeout = nil
        let continuation = writeContinuation
        writeContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

extension BoatCentral {
    public func refreshFirmware() {
        guard let peripheral, let otaInfoCharacteristic else { return }
        peripheral.readValue(for: otaInfoCharacteristic)
    }

    public func cancelFirmwareInstall() {
        guard installing, !installStop else { return }
        installStop = true
        failFirmwareWaiters(CancellationError())
    }

    public func installFirmware(_ image: FirmwareImage) -> AsyncThrowingStream<FirmwarePushProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard !self.installing else {
                    continuation.finish(throwing: FirmwareUpdateError.busy)
                    return
                }
                self.installing = true
                self.installStop = false
                defer { self.installing = false }
                do {
                    try await self.runInstall(image) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { @MainActor in
                    self.cancelFirmwareInstall()
                }
            }
        }
    }

    private func adoptFirmware(_ service: CBService, error: Error?) {
        guard error == nil, let peripheral else {
            firmwareAvailability = .unsupported
            return
        }
        let found = service.characteristics ?? []
        guard
            let info = found.first(where: { $0.uuid == BoatBluetooth.otaInfoUUID }),
            let control = found.first(where: { $0.uuid == BoatBluetooth.otaControlUUID }),
            let data = found.first(where: { $0.uuid == BoatBluetooth.otaDataUUID })
        else {
            firmwareAvailability = .unsupported
            return
        }
        otaInfoCharacteristic = info
        otaControlCharacteristic = control
        otaDataCharacteristic = data
        peripheral.setNotifyValue(true, for: info)
        peripheral.readValue(for: info)
    }

    private func noteFirmware(_ info: DeviceFirmwareInfo) {
        firmwareEpoch += 1
        firmwareAvailability = .available(info)
        guard let predicate = infoPredicate, predicate(info) else { return }
        infoPredicate = nil
        infoTimeout?.cancel()
        infoTimeout = nil
        let continuation = infoContinuation
        infoContinuation = nil
        continuation?.resume(returning: info)
    }

    private func currentFirmware() -> DeviceFirmwareInfo? {
        if case .available(let info) = firmwareAvailability { return info }
        return nil
    }

    private func failFirmwareWaiters(_ error: Error) {
        infoTimeout?.cancel()
        infoTimeout = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        infoPredicate = nil
        let info = infoContinuation
        infoContinuation = nil
        info?.resume(throwing: error)
        let write = writeContinuation
        writeContinuation = nil
        write?.resume(throwing: error)
    }

    private func runInstall(
        _ image: FirmwareImage,
        yield: (FirmwarePushProgress) -> Void
    ) async throws {
        var rebootStarted = false
        do {
            try await transfer(image, rebootStarted: &rebootStarted, yield: yield)
        } catch is CancellationError {
            if rebootStarted { return }
            try? await writeControl(Data([FirmwareProtocol.abortCommand]), timeout: 3)
            throw CancellationError()
        } catch {
            if rebootStarted, peripheral == nil { return }
            if rebootStarted, case FirmwareUpdateError.disconnected = error { return }
            throw error
        }
    }

    private func transfer(
        _ image: FirmwareImage,
        rebootStarted: inout Bool,
        yield: (FirmwarePushProgress) -> Void
    ) async throws {
        guard status == .ready, peripheral != nil else { throw FirmwareUpdateError.notReady }
        guard case .available(let device) = firmwareAvailability else {
            throw firmwareAvailability == .unsupported ? FirmwareUpdateError.unsupported : FirmwareUpdateError.notReady
        }
        guard device.hardware == image.hardware else { throw FirmwareUpdateError.wrongHardware }
        guard device.slotSize > 0 else { throw FirmwareUpdateError.device(DeviceFirmwareError(code: 10)) }
        guard image.bytes.count <= Int(device.slotSize) else { throw FirmwareUpdateError.tooLarge }
        guard let peripheral, let dataCharacteristic = otaDataCharacteristic else {
            throw FirmwareUpdateError.unsupported
        }

        yield(FirmwarePushProgress(phase: .preparing, sent: 0, total: image.bytes.count))
        let begin = FirmwareProtocol.beginCommand(size: image.bytes.count, crc32: image.crc32, version: image.version)
        try await writeControl(begin, timeout: 15)
        let started = try await waitOrRead(timeout: 15) { info in
            (info.state == .receiving && info.imageSize == image.bytes.count && info.error.code == 0) || info.failed
        }
        if started.failed { throw FirmwareUpdateError.device(started.error) }

        let payloadSize = FirmwareProtocol.payloadSize(
            writeLength: peripheral.maximumWriteValueLength(for: .withResponse)
        )
        var offset = 0
        var stalls = 0
        while offset < image.bytes.count {
            if installStop || Task.isCancelled { throw CancellationError() }
            let length = min(payloadSize, image.bytes.count - offset)
            let payload = image.bytes.subdata(in: offset..<(offset + length))
            try await writeFirmware(FirmwareProtocol.dataCommand(offset: offset, payload: payload), for: dataCharacteristic, timeout: 8)
            let target = offset + length
            let info = try await awaitAccepted(through: target)
            if info.failed { throw FirmwareUpdateError.device(info.error) }
            if info.received < target {
                stalls += 1
                guard stalls < 3 else { throw FirmwareUpdateError.timedOut }
                offset = min(info.received, image.bytes.count)
                continue
            }
            stalls = 0
            offset = info.received
            yield(FirmwarePushProgress(phase: .sending, sent: offset, total: image.bytes.count))
        }

        yield(FirmwarePushProgress(phase: .verifying, sent: image.bytes.count, total: image.bytes.count))
        try await writeControl(Data([FirmwareProtocol.commitCommand]), timeout: 8)
        let verified = try await waitOrRead(timeout: 45) { info in
            info.state == .verified || info.failed
        }
        if verified.failed || verified.state != .verified {
            throw FirmwareUpdateError.device(verified.error)
        }

        yield(FirmwarePushProgress(phase: .restarting, sent: image.bytes.count, total: image.bytes.count))
        rebootStarted = true
        quietDisconnect = true
        try? await writeControl(Data([FirmwareProtocol.rebootCommand]), timeout: 5)
        let dropped = await waitForDisconnect(timeout: 8)
        if dropped { return }
        if let info = try? await readFirmware(timeout: 3), info.failed {
            quietDisconnect = false
            throw FirmwareUpdateError.device(info.error)
        }
        quietDisconnect = false
        throw FirmwareUpdateError.timedOut
    }

    private func waitOrRead(
        timeout: TimeInterval,
        where predicate: @escaping (DeviceFirmwareInfo) -> Bool
    ) async throws -> DeviceFirmwareInfo {
        do {
            return try await awaitFirmware(timeout: timeout, where: predicate)
        } catch FirmwareUpdateError.timedOut {
            let info = try await readFirmware(timeout: 4)
            if predicate(info) { return info }
            throw FirmwareUpdateError.timedOut
        }
    }

    private func awaitAccepted(through end: Int) async throws -> DeviceFirmwareInfo {
        if let info = currentFirmware(), info.received >= end || info.failed {
            return info
        }
        do {
            return try await awaitFirmware(timeout: 8) { info in
                info.received >= end || info.failed
            }
        } catch FirmwareUpdateError.timedOut {
            return try await readFirmware(timeout: 4)
        }
    }

    private func awaitFirmware(
        timeout: TimeInterval,
        where predicate: @escaping (DeviceFirmwareInfo) -> Bool
    ) async throws -> DeviceFirmwareInfo {
        if let info = currentFirmware(), predicate(info) {
            return info
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.infoPredicate = predicate
            self.infoContinuation = continuation
            self.infoTimeout?.cancel()
            self.infoTimeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.infoPredicate = nil
                let pending = self.infoContinuation
                self.infoContinuation = nil
                pending?.resume(throwing: FirmwareUpdateError.timedOut)
            }
        }
    }

    private func readFirmware(timeout: TimeInterval) async throws -> DeviceFirmwareInfo {
        guard let peripheral, let otaInfoCharacteristic else { throw FirmwareUpdateError.disconnected }
        let epoch = firmwareEpoch
        peripheral.readValue(for: otaInfoCharacteristic)
        return try await awaitFirmware(timeout: timeout) { _ in
            self.firmwareEpoch > epoch
        }
    }

    private func writeControl(_ data: Data, timeout: TimeInterval) async throws {
        guard let characteristic = otaControlCharacteristic else { throw FirmwareUpdateError.disconnected }
        try await writeFirmware(data, for: characteristic, timeout: timeout)
    }

    private func writeFirmware(_ data: Data, for characteristic: CBCharacteristic, timeout: TimeInterval) async throws {
        guard let peripheral else { throw FirmwareUpdateError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeContinuation = continuation
            self.writeTimeout?.cancel()
            self.writeTimeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let pending = self.writeContinuation
                self.writeContinuation = nil
                pending?.resume(throwing: FirmwareUpdateError.timedOut)
            }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        writeTimeout?.cancel()
        writeTimeout = nil
    }

    private func waitForDisconnect(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if peripheral == nil { return true }
            if installStop { return peripheral == nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return peripheral == nil
    }
}
