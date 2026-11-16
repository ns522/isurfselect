import CryptoKit
import Foundation

/// ESP32-S3 image identity carried over the firmware BLE service.
public enum FirmwareHardware: UInt8, Equatable, Sendable {
    case esp32s3 = 1

    public var chipID: UInt16 {
        switch self {
        case .esp32s3:
            0x0009
        }
    }

    public var manifestName: String {
        switch self {
        case .esp32s3:
            "esp32s3"
        }
    }

    public init?(manifestName: String) {
        switch manifestName.lowercased() {
        case "esp32s3", "esp32-s3":
            self = .esp32s3
        default:
            return nil
        }
    }
}

public struct FirmwareVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `1.2.0` or `1.2`. Anything else, including a filename, fails.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = FirmwareVersion.parse(trimmed) else { return nil }
        self = parsed
    }

    /// First `major.minor` or `major.minor.patch` run inside `text`.
    public init?(scanning text: String) {
        let scalars = Array(text)
        var index = 0
        while index < scalars.count {
            if scalars[index].isNumber {
                var end = index
                while end < scalars.count {
                    let scalar = scalars[end]
                    if scalar.isNumber {
                        end += 1
                    } else if scalar == ".", end + 1 < scalars.count, scalars[end + 1].isNumber {
                        end += 1
                    } else {
                        break
                    }
                }
                let token = String(scalars[index..<end])
                if let parsed = FirmwareVersion.parse(token) {
                    self = parsed
                    return
                }
                index = end
            } else {
                index += 1
            }
        }
        return nil
    }

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parse(_ text: String) -> FirmwareVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0 else { return nil }
        let patch: Int
        if parts.count == 3 {
            guard let value = Int(parts[2]), value >= 0 else { return nil }
            patch = value
        } else {
            patch = 0
        }
        return FirmwareVersion(major: major, minor: minor, patch: patch)
    }
}

public enum FirmwareChecksum {
    /// zlib / ISO-HDLC CRC-32. Pass the previous result as `continuing` to cover a file in pieces.
    public static func crc32(_ data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        var crc = ~crc
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 0 ? 0 : 0xEDB8_8320
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }
}

public enum EspAppImage {
    public static let magic: UInt8 = 0xE9
    public static let appDescriptionMagic: UInt32 = 0xABCD5432
    public static let headerLength = 36

    public static func chipID(_ bytes: Data) -> UInt16? {
        guard bytes.count >= 14, bytes.first == magic else { return nil }
        return UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
    }

    public static func isApplication(_ bytes: Data) -> Bool {
        guard bytes.count >= headerLength, bytes.first == magic else { return false }
        return u32(bytes, 32) == appDescriptionMagic
    }
}

public struct DeviceFirmwareError: Equatable, Sendable {
    public var code: UInt8

    public var message: String {
        switch code {
        case 0:
            "The bridge reported a failure."
        case 1:
            "The bridge rejected the update command."
        case 2:
            "That file is larger than the bridge's update slot."
        case 3:
            "The bridge lost its place in the file. Start the update again."
        case 4:
            "The bridge could not write the update."
        case 5:
            "The bridge checksum did not match the file."
        case 6:
            "The bridge rejected the file. Use the app .bin from Arduino."
        case 7:
            "The bridge is already applying an update. Restart it, then try again."
        case 8:
            "The file transfer stopped before the end."
        case 9:
            "That file is not an iSurfSelect ESP32-S3 firmware image."
        case 10:
            "This bridge was flashed without an OTA slot. Reflash it over USB with the Default 4MB with spiffs partition scheme."
        default:
            "The bridge rejected the update (\(code))."
        }
    }
}

public enum DeviceFirmwareState: Equatable, Sendable {
    case idle
    case receiving
    case verified
    case error
    case verifying
    case other(UInt8)

    init(byte: UInt8) {
        switch byte {
        case 0: self = .idle
        case 1: self = .receiving
        case 2: self = .verified
        case 3: self = .error
        case 4: self = .verifying
        default: self = .other(byte)
        }
    }
}

public struct DeviceFirmwareInfo: Equatable, Sendable {
    public var version: String
    public var hardware: FirmwareHardware
    public var state: DeviceFirmwareState
    public var error: DeviceFirmwareError
    public var slot: UInt8
    public var slotSize: UInt32
    public var received: Int
    public var imageSize: Int
    public var imageCRC: UInt32
    public var receivedCRC: UInt32

    public var failed: Bool {
        if state == .error { return true }
        if error.code == 0 { return false }
        return state != .receiving && state != .verifying
    }
}

public enum FirmwareAvailability: Equatable, Sendable {
    case unknown
    case unsupported
    case available(DeviceFirmwareInfo)
}

public struct FirmwarePushProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case sending
        case verifying
        case restarting
    }

    public var phase: Phase
    public var sent: Int
    public var total: Int

    public init(phase: Phase, sent: Int, total: Int) {
        self.phase = phase
        self.sent = sent
        self.total = total
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(sent) / Double(total))
    }
}

public enum FirmwareUpdateError: Error, Equatable, Sendable {
    case notReady
    case unsupported
    case disconnected
    case busy
    case timedOut
    case notEspImage
    case wrongHardware
    case tooLarge
    case manifest(String)
    case device(DeviceFirmwareError)
}

extension FirmwareUpdateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReady:
            "Connect to the bridge first."
        case .unsupported:
            "This bridge needs one USB flash of the updater firmware before the phone can install updates."
        case .disconnected:
            "Bluetooth disconnected during the update."
        case .busy:
            "An update is already running."
        case .timedOut:
            "The bridge stopped answering. Stay close to the boat and try again."
        case .notEspImage:
            "Choose the app .bin exported from Arduino, not the bootloader or partition file."
        case .wrongHardware:
            "That file is not built for this ESP32-S3."
        case .tooLarge:
            "That file is larger than the bridge's update slot (about 1.2 MB)."
        case .manifest(let message):
            message
        case .device(let error):
            error.message
        }
    }
}

public struct FirmwareImage: Equatable, Sendable {
    public var version: String
    public var hardware: FirmwareHardware
    public var bytes: Data
    public var notes: String?
    public var crc32: UInt32

    public init(version: String, hardware: FirmwareHardware, bytes: Data, notes: String? = nil) throws {
        guard EspAppImage.isApplication(bytes) else { throw FirmwareUpdateError.notEspImage }
        guard EspAppImage.chipID(bytes) == hardware.chipID else { throw FirmwareUpdateError.wrongHardware }
        self.version = version
        self.hardware = hardware
        self.bytes = bytes
        self.notes = notes
        self.crc32 = FirmwareChecksum.crc32(bytes)
    }
}

public struct FirmwareManifest: Codable, Equatable, Sendable {
    public var hardware: String
    public var version: String
    public var size: Int
    public var crc32: String
    public var sha256: String?
    public var url: URL
    public var notes: String?

    public func image(from bytes: Data) throws -> FirmwareImage {
        guard let hardware = FirmwareHardware(manifestName: hardware) else {
            throw FirmwareUpdateError.manifest("The manifest is for \(hardware), not this bridge.")
        }
        guard size == bytes.count else {
            throw FirmwareUpdateError.manifest("The download is \(bytes.count) bytes. The manifest says \(size).")
        }
        guard let expectedCRC = FirmwareProtocol.parseHex32(crc32) else {
            throw FirmwareUpdateError.manifest("The manifest checksum is not an 8-digit hex CRC-32.")
        }
        let actualCRC = FirmwareChecksum.crc32(bytes)
        guard actualCRC == expectedCRC else {
            throw FirmwareUpdateError.manifest("The download checksum does not match the manifest.")
        }
        if let sha256 {
            let trimmed = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var hex = trimmed.lowercased()
                if hex.hasPrefix("0x") {
                    hex.removeFirst(2)
                }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard hex == digest else {
                    throw FirmwareUpdateError.manifest("The download SHA-256 does not match the manifest.")
                }
            }
        }
        let image = try FirmwareImage(version: version, hardware: hardware, bytes: bytes, notes: notes)
        guard image.hardware == hardware else { throw FirmwareUpdateError.wrongHardware }
        return image
    }
}

public enum FirmwareCatalog {
    public static func fetch(manifestURL: URL, session: URLSession = .shared) async throws -> FirmwareImage {
        let (manifestData, manifestResponse) = try await session.data(from: manifestURL)
        try Self.requireHTTP(manifestResponse, what: "manifest")
        let manifest: FirmwareManifest
        do {
            manifest = try JSONDecoder().decode(FirmwareManifest.self, from: manifestData)
        } catch {
            throw FirmwareUpdateError.manifest("The manifest is not the expected JSON.")
        }
        let (bytes, imageResponse) = try await session.data(from: manifest.url)
        try Self.requireHTTP(imageResponse, what: "firmware file")
        return try manifest.image(from: bytes)
    }

    private static func requireHTTP(_ response: URLResponse, what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FirmwareUpdateError.manifest("The \(what) request failed (\(http.statusCode)).")
        }
    }
}

public enum FirmwareProtocol {
    public static let infoLength = 44
    public static let magic: UInt16 = 0x4F53
    public static let beginCommand: UInt8 = 1
    public static let abortCommand: UInt8 = 2
    public static let commitCommand: UInt8 = 3
    public static let rebootCommand: UInt8 = 4
    public static let dataHeaderLength = 4
    public static let maxPacketLength = 512

    public static func payloadSize(writeLength: Int) -> Int {
        let packet = min(max(writeLength, dataHeaderLength + 1), maxPacketLength)
        return packet - dataHeaderLength
    }

    public static func offsets(byteCount: Int, payloadSize: Int) -> [Int] {
        guard byteCount > 0 else { return [] }
        let size = max(1, payloadSize)
        var offset = 0
        var marks: [Int] = []
        while offset < byteCount {
            marks.append(offset)
            offset += min(size, byteCount - offset)
        }
        return marks
    }

    public static func beginCommand(size: Int, crc32: UInt32, version: String) -> Data {
        var data = Data([Self.beginCommand])
        append(UInt32(size), to: &data)
        append(crc32, to: &data)
        let text = Data(version.utf8.prefix(15))
        data.append(text)
        return data
    }

    public static func dataCommand(offset: Int, payload: Data) -> Data {
        var data = Data()
        append(UInt32(offset), to: &data)
        data.append(payload)
        return data
    }

    public static func decodeInfo(_ data: Data) -> DeviceFirmwareInfo? {
        guard data.count >= infoLength else { return nil }
        let magic = UInt16(data[0]) | (UInt16(data[1]) << 8)
        guard magic == Self.magic, data[2] == 1 else { return nil }
        guard let hardware = FirmwareHardware(rawValue: data[3]) else { return nil }
        let versionBytes = data.subdata(in: 4..<20)
        let versionEnd = versionBytes.firstIndex(of: 0) ?? versionBytes.endIndex
        let version = String(data: versionBytes[..<versionEnd], encoding: .utf8) ?? ""
        return DeviceFirmwareInfo(
            version: version,
            hardware: hardware,
            state: DeviceFirmwareState(byte: data[20]),
            error: DeviceFirmwareError(code: data[21]),
            slot: data[22],
            slotSize: u32(data, 24),
            received: Int(u32(data, 28)),
            imageSize: Int(u32(data, 32)),
            imageCRC: u32(data, 36),
            receivedCRC: u32(data, 40)
        )
    }

    public static func parseHex32(_ raw: String) -> UInt32? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") {
            text.removeFirst(2)
        }
        guard text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        return value
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}
