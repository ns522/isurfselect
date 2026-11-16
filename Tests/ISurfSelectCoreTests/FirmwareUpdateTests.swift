import CryptoKit
import Foundation
import Testing
@testable import ISurfSelectCore

struct FirmwareUpdateTests {
    @Test func crc32MatchesTheStandardVector() {
        let data = Data("123456789".utf8)
        #expect(FirmwareChecksum.crc32(data) == 0xCBF4_3926)

        var rolling: UInt32 = 0
        rolling = FirmwareChecksum.crc32(Data("12345".utf8), continuing: rolling)
        rolling = FirmwareChecksum.crc32(Data("6789".utf8), continuing: rolling)
        #expect(rolling == 0xCBF4_3926)
    }

    @Test func versionOrder() {
        #expect(FirmwareVersion("1.2.0")! > FirmwareVersion("1.1.9")!)
        #expect(FirmwareVersion("1.10.0")! > FirmwareVersion("1.9.0")!)
        #expect(FirmwareVersion("1.2") == FirmwareVersion("1.2.0"))
        #expect(FirmwareVersion("1.2.0-beta") == nil)
        #expect(FirmwareVersion(scanning: "isurfselect-1.2.3.bin") == FirmwareVersion("1.2.3"))
        #expect(FirmwareVersion(scanning: "isurfselect-s3.ino") == nil)
    }

    @Test func infoPacketDecodesTheBridgeLayout() {
        var data = Data(repeating: 0, count: 44)
        data[0] = 0x53
        data[1] = 0x4F
        data[2] = 1
        data[3] = 1
        let version = Data("1.0.0".utf8)
        data.replaceSubrange(4..<(4 + version.count), with: version)
        data[20] = 1
        data[21] = 0
        data[22] = 1
        data[23] = 0
        write(UInt32(0x140000), at: 24, into: &data)
        write(UInt32(1200), at: 28, into: &data)
        write(UInt32(5000), at: 32, into: &data)
        write(UInt32(0xAABBCCDD), at: 36, into: &data)
        write(UInt32(0x01020304), at: 40, into: &data)

        let info = FirmwareProtocol.decodeInfo(data)
        #expect(info?.version == "1.0.0")
        #expect(info?.hardware == .esp32s3)
        #expect(info?.state == .receiving)
        #expect(info?.error.code == 0)
        #expect(info?.slot == 1)
        #expect(info?.slotSize == 0x140000)
        #expect(info?.received == 1200)
        #expect(info?.imageSize == 5000)
        #expect(info?.imageCRC == 0xAABBCCDD)
        #expect(info?.receivedCRC == 0x01020304)
        #expect(info?.failed == false)

        data[0] = 0
        #expect(FirmwareProtocol.decodeInfo(data) == nil)
    }

    @Test func commandsUseLittleEndianOffsets() {
        let begin = FirmwareProtocol.beginCommand(size: 2, crc32: 0x10, version: "1.2.0")
        #expect(Array(begin) == [1, 2, 0, 0, 0, 0x10, 0, 0, 0, 0x31, 0x2E, 0x32, 0x2E, 0x30])
        let chunk = FirmwareProtocol.dataCommand(offset: 0x01020304, payload: Data([0xAA]))
        #expect(Array(chunk) == [0x04, 0x03, 0x02, 0x01, 0xAA])
        #expect(FirmwareProtocol.offsets(byteCount: 100, payloadSize: 30) == [0, 30, 60, 90])
        #expect(FirmwareProtocol.payloadSize(writeLength: 514) == 508)
    }

    @Test func imageRejectsBootloaderAndWrongChip() throws {
        let app = try FirmwareImage(version: "1.0.0", hardware: .esp32s3, bytes: appImage())
        #expect(app.crc32 == FirmwareChecksum.crc32(appImage()))

        #expect(throws: FirmwareUpdateError.notEspImage) {
            try FirmwareImage(version: "boot", hardware: .esp32s3, bytes: appImage(desc: 0xFFFF_FFFF))
        }
        #expect(throws: FirmwareUpdateError.wrongHardware) {
            try FirmwareImage(version: "c3", hardware: .esp32s3, bytes: appImage(chip: 0x0005))
        }
    }

    @Test func manifestChecksSizeChecksumAndHash() throws {
        let bytes = appImage(extra: 8)
        let crc = FirmwareChecksum.crc32(bytes)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = try manifestJSON(size: bytes.count, crc: crc, sha: sha, notes: "Ballast fix")
        let image = try manifest.image(from: bytes)
        #expect(image.version == "1.2.0")
        #expect(image.notes == "Ballast fix")
        #expect(image.crc32 == crc)

        #expect(throws: FirmwareUpdateError.self) {
            try manifest.image(from: appImage(extra: 4))
        }
        let wrong = try manifestJSON(size: bytes.count, crc: crc, sha: String(repeating: "ab", count: 32), notes: nil)
        #expect(throws: FirmwareUpdateError.self) {
            try wrong.image(from: bytes)
        }
    }

    private func appImage(chip: UInt16 = 0x0009, desc: UInt32 = 0xABCD5432, extra: Int = 28) -> Data {
        var bytes = Data(repeating: 0x11, count: EspAppImage.headerLength + extra)
        bytes[0] = EspAppImage.magic
        bytes[12] = UInt8(chip & 0xFF)
        bytes[13] = UInt8(chip >> 8)
        write(desc, at: 32, into: &bytes)
        return bytes
    }

    private func manifestJSON(size: Int, crc: UInt32, sha: String, notes: String?) throws -> FirmwareManifest {
        var object: [String: Any] = [
            "hardware": "esp32s3",
            "version": "1.2.0",
            "size": size,
            "crc32": String(format: "%08x", crc),
            "sha256": sha,
            "url": "https://example.com/isurfselect-s3.bin",
        ]
        if let notes {
            object["notes"] = notes
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FirmwareManifest.self, from: data)
    }
}

private func write(_ value: UInt32, at offset: Int, into data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { raw in
        for (index, byte) in raw.enumerated() {
            data[offset + index] = byte
        }
    }
}
