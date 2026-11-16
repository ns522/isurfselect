import Foundation

/// Six-byte payload for CAN command `0x14EF4C11`.
///
/// Byte 0 holds the shape in bits 7...4 and the side in bit 3 (1 = starboard, 0 = port).
/// Byte 1 bit 0 is the underwater lights. Byte 2 is speed in tenths of a mile per hour.
/// Byte 4 is volume. Byte 5 bit 0 is shifting. Every other bit is preserved.
public struct SurfFrame: Equatable, Sendable {
    public static let length = 6
    /// Bluetooth state and command length used by the ESP32 bridge.
    public static let linkLength = 5
    /// Magic header byte for explicit BLE commands sent to the ESP32 bridge.
    public static let commandMagic: UInt8 = 0xA5
    public static let shapeRange = 0...10
    public static let volumeRange = 0...40
    public static let ballastPoundsRange = 50...400
    public static let ballastPoundsStep = 50

    /// Encodes a ballast shift request (`50...400` lbs in `50` lb steps) into the CAN/BLE command byte.
    public static func ballastCommandByte(port: Bool, pounds: Int) -> UInt8 {
        let clamped = min(max(pounds, 0), ballastPoundsRange.upperBound)
        let steps = min(max((clamped + 25) / ballastPoundsStep, 1), 8)
        return UInt8((steps << 2) | (port ? 0x01 : 0x02))
    }

    /// Captured idle frame: shape 4, port, 12.1 mph, volume 7, lights off, shift idle.
    private static let template: [UInt8] = [0x45, 0x00, 0x79, 0x00, 0x07, 0x0A]

    private var raw: [UInt8]

    public init(
        shape: Int = 4,
        port: Bool = true,
        speedTenths: Int = 121,
        volume: Int = 7,
        lights: Bool = false,
        shifting: Bool = false
    ) {
        self.raw = Self.template
        self.shape = shape
        self.port = port
        self.speedTenths = speedTenths
        self.volume = volume
        self.lights = lights
        self.shifting = shifting
    }

    /// Decodes a frame. Fewer than six bytes keep the bytes that arrived and take the rest from the template.
    public init(bytes: Data) {
        var raw = Self.template
        for (index, byte) in bytes.prefix(Self.length).enumerated() {
            raw[index] = byte
        }
        self.raw = raw
    }

    public var shape: Int {
        get { Int(raw[0] >> 4) }
        set { raw[0] = (UInt8(newValue & 0x0F) << 4) | (raw[0] & 0x0F) }
    }

    /// `true` is port. The boat's captures use low nibble 5 for port and D for starboard.
    public var port: Bool {
        get { raw[0] & 0x08 == 0 }
        set {
            let shape = raw[0] & 0xF0
            raw[0] = shape | (newValue ? 0x05 : 0x0D)
        }
    }

    public var speedTenths: Int {
        get { Int(raw[2]) }
        set { raw[2] = UInt8(clamping: newValue) }
    }

    public var volume: Int {
        get { Int(raw[4]) }
        set { raw[4] = UInt8(clamping: min(max(newValue, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)) }
    }

    public var lights: Bool {
        get { raw[1] & 0x01 != 0 }
        set {
            if newValue {
                raw[1] |= 0x01
            } else {
                raw[1] &= ~UInt8(0x01)
            }
        }
    }

    public var shifting: Bool {
        get { raw[5] & 0x01 != 0 }
        set {
            if newValue {
                raw[5] |= 0x01
            } else {
                raw[5] &= ~UInt8(0x01)
            }
        }
    }

    public var data: Data { Data(raw) }

    /// Five bytes on the boat's Bluetooth characteristics: shape, side, speed tenths, volume, flags.
    /// Side is 0 for port and 1 for starboard. Flags bit 0 is shift, bit 1 is underwater lights.
    public var linkData: Data {
        var flags: UInt8 = 0
        if shifting { flags |= 0x01 }
        if lights { flags |= 0x02 }
        return Data([
            UInt8(shape & 0x0F),
            port ? 0 : 1,
            UInt8(clamping: speedTenths),
            UInt8(clamping: volume),
            flags,
        ])
    }

    /// Decodes the 5-byte Bluetooth state. Reserved CAN bits are not on this link, so they stay at the template.
    public init(linkBytes: Data) {
        self.init()
        guard linkBytes.count >= Self.linkLength else { return }
        let bytes = [UInt8](linkBytes.prefix(Self.linkLength))
        shape = Int(bytes[0] & 0x0F)
        port = bytes[1] == 0
        speedTenths = Int(bytes[2])
        volume = Int(bytes[3])
        shifting = bytes[4] & 0x01 != 0
        lights = bytes[4] & 0x02 != 0
    }

    /// Encodes a boat command as an explicit `0xA5`-prefixed BLE packet.
    /// Returns `nil` for local-only UI actions such as `.leaveWater`.
    public static func commandData(for command: BoatCommand) -> Data? {
        switch command {
        case .side(let port):
            return Data([commandMagic, 0x01, port ? 0x01 : 0x03])
        case .speed(let tenths):
            return Data([commandMagic, 0x02, UInt8(clamping: min(max(tenths, 0), 255))])
        case .volume(let volume):
            return Data([commandMagic, 0x03, UInt8(clamping: min(max(volume, volumeRange.lowerBound), volumeRange.upperBound))])
        case .shape(let shape):
            return Data([commandMagic, 0x04, UInt8(clamping: min(max(shape, shapeRange.lowerBound), shapeRange.upperBound))])
        case .ballast(let port, let pounds):
            return Data([commandMagic, 0x05, ballastCommandByte(port: port, pounds: pounds)])
        case .zoneVolume(let id, let level):
            return Data([
                commandMagic,
                0x06,
                UInt8(clamping: id),
                UInt8(StereoZone.percent(fromLevel: level)),
            ])
        case .zoneStep(let id, let up):
            return Data([commandMagic, 0x07, UInt8(clamping: id), up ? 0x00 : 0x01])
        case .refreshZones:
            return Data([commandMagic, 0x08, 0x00])
        case .stopBallast:
            return Data([commandMagic, 0x09, 0x03])
        case .track(let next):
            return Data([commandMagic, 0x0A, next ? 0x0B : 0x0C])
        case .leaveWater:
            return nil
        }
    }

    public func applying(_ command: BoatCommand) -> SurfFrame {
        var next = self
        switch command {
        case .side(let port):
            next.port = port
        case .speed(let tenths):
            next.speedTenths = min(max(tenths, 0), 255)
        case .volume(let volume):
            next.volume = volume
        case .shape(let shape):
            let lower = Self.shapeRange.lowerBound
            let upper = Self.shapeRange.upperBound
            next.shape = min(max(shape, lower), upper)
        case .ballast:
            next.shifting = true
        case .stopBallast:
            next.shifting = false
        case .track, .zoneVolume, .zoneStep, .refreshZones, .leaveWater:
            break
        }
        return next
    }

    public var boatState: BoatState {
        BoatState(port: port, speedTenths: speedTenths, volume: volume, shifting: shifting)
    }
}

/// Stereo zone discovered dynamically over NMEA 2000 (`PGN 130574` / JL Audio MediaMaster).
/// `volume` is the LINC 0–50 level. The bus still carries 0–100 percent.
public struct StereoZone: Equatable, Identifiable, Sendable {
    public static let volumeRange = 0...50
    public static let stepSize = 1
    public static let formatVersion: UInt8 = 0x01
    public static let maxZones = 8

    public var id: Int
    public var name: String
    public var volume: Int
    public var muted: Bool

    public init(id: Int, name: String, volume: Int, muted: Bool = false) {
        self.id = id
        let cleaned = name
            .split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = cleaned.isEmpty ? "Zone \(id)" : cleaned
        self.volume = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
        self.muted = muted
    }

    /// LINC shows 0–50. One step is 2 percent on the stereo bus.
    public static func level(fromPercent percent: Int) -> Int {
        let clamped = min(max(percent, 0), 100)
        return min(volumeRange.upperBound, (clamped + 1) / 2)
    }

    /// Converts a LINC 0–50 level into the percent the stereo command expects.
    public static func percent(fromLevel level: Int) -> Int {
        let clamped = min(max(level, volumeRange.lowerBound), volumeRange.upperBound)
        return min(100, clamped * 2)
    }

    /// Encodes zones into the `BoatBluetooth.zonesUUID` wire format.
    public static func encodeZones(_ zones: [StereoZone]) -> Data {
        let capped = Array(zones.prefix(maxZones))
        var bytes: [UInt8] = [formatVersion, UInt8(capped.count)]
        for zone in capped {
            let zoneId = UInt8(clamping: zone.id)
            let clampedVol = UInt8(percent(fromLevel: zone.volume))
            let volByte: UInt8 = (zone.muted ? 0x80 : 0x00) | clampedVol
            let utf8 = Array(zone.name.utf8.prefix(255))
            bytes.append(zoneId)
            bytes.append(volByte)
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        return Data(bytes)
    }

    /// Decodes zones from the `BoatBluetooth.zonesUUID` wire format, returning `nil` if malformed or truncated.
    public static func decodeZones(_ data: Data) -> [StereoZone]? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == formatVersion else { return nil }
        let count = Int(bytes[1])
        guard count <= maxZones else { return nil }

        var index = 2
        var zones: [StereoZone] = []
        zones.reserveCapacity(count)

        for _ in 0..<count {
            guard index + 3 <= bytes.count else { return nil }
            let zoneId = Int(bytes[index])
            let volByte = bytes[index + 1]
            let nameLen = Int(bytes[index + 2])
            index += 3

            guard index + nameLen <= bytes.count else { return nil }
            let nameSlice = bytes[index..<(index + nameLen)]
            index += nameLen

            guard let rawName = String(bytes: nameSlice, encoding: .utf8) else { return nil }
            let muted = (volByte & 0x80) != 0
            let volume = level(fromPercent: Int(volByte & 0x7F))
            zones.append(StereoZone(id: zoneId, name: rawName, volume: volume, muted: muted))
        }

        guard index == bytes.count else { return nil }
        return zones
    }

    /// Picks the wake/tower speaker zone for quick rider control on Apple Watch.
    public static func wakeZone(in zones: [StereoZone]) -> StereoZone? {
        if let wake = zones.first(where: { $0.name.localizedCaseInsensitiveContains("wake") }) {
            return wake
        }
        if let tower = zones.first(where: { $0.name.localizedCaseInsensitiveContains("tower") }) {
            return tower
        }
        return zones.last
    }
}
