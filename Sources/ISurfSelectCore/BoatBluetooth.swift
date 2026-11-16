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
}
