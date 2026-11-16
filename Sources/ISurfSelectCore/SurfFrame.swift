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
    /// Magic header byte for explicit 3-byte BLE commands sent to the ESP32 bridge.
    public static let commandMagic: UInt8 = 0xA5
    public static let shapeRange = 0...10
    public static let volumeRange = 0...40

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

    /// Encodes a boat command as an explicit 3-byte BLE packet (`[0xA5, opcode, value]`).
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
        case .ballast(let port):
            return Data([commandMagic, 0x05, port ? 0x09 : 0x0A])
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
        case .ballast(let port):
            next.shifting = true
            next.port = port
        case .leaveWater:
            break
        }
        return next
    }

    public var boatState: BoatState {
        BoatState(port: port, speedTenths: speedTenths, volume: volume)
    }
}
