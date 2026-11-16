import CoreBluetooth

public enum BoatLinkStatus: Equatable, Sendable {
    case off
    case scanning
    case connecting
    case ready
    case failed(String)
}

public enum BoatBluetooth {
    /// Advertised name of the Waveshare ESP32-S3 bridge.
    public static let localName = "iSurfSelect"
    // CBUUID values are immutable. The class is not Sendable, so these constants opt out of the checker.
    nonisolated(unsafe) public static let serviceUUID = CBUUID(string: "7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let frameUUID = CBUUID(string: "7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let commandUUID = CBUUID(string: "7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let songUUID = CBUUID(string: "7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let zonesUUID = CBUUID(string: "7c4e0005-6f3b-4a1e-9c55-1b2d3e4f5061")
    /// Firmware push from the phone. The watch does not use this service.
    nonisolated(unsafe) public static let otaServiceUUID = CBUUID(string: "7c4e0010-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let otaInfoUUID = CBUUID(string: "7c4e0011-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let otaControlUUID = CBUUID(string: "7c4e0012-6f3b-4a1e-9c55-1b2d3e4f5061")
    nonisolated(unsafe) public static let otaDataUUID = CBUUID(string: "7c4e0013-6f3b-4a1e-9c55-1b2d3e4f5061")
}
