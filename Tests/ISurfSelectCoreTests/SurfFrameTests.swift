import CoreBluetooth
import Foundation
import Testing
@testable import ISurfSelectCore

struct SurfFrameTests {
    private let template = Data([0x45, 0x00, 0x79, 0x00, 0x07, 0x0A])
    private let captured = Data([0x45, 0x00, 0x79, 0x00, 0x08, 0x0A])

    @Test func capturedPayloadRoundTrips() {
        var port = SurfFrame(bytes: captured)
        port.shape = 4
        port.port = true
        port.speedTenths = 121
        port.volume = 7
        port.shifting = false
        port.lights = false
        #expect(port.data == template)
        #expect(port.shape == 4)
        #expect(port.port)
        #expect(port.speedTenths == 121)
        #expect(port.volume == 7)
        #expect(!port.lights)
        #expect(!port.shifting)

        var lights = SurfFrame(bytes: captured)
        lights.shape = 4
        lights.port = true
        lights.speedTenths = 121
        lights.volume = 7
        lights.shifting = false
        lights.lights = true
        #expect(lights.data == Data([0x45, 0x01, 0x79, 0x00, 0x07, 0x0A]))
        #expect(lights.data[1] == 0x01)

        var starboard = SurfFrame(bytes: captured)
        starboard.shape = 5
        starboard.port = false
        starboard.speedTenths = 122
        starboard.volume = 5
        starboard.shifting = false
        starboard.lights = false
        #expect(starboard.data == Data([0x5D, 0x00, 0x7A, 0x00, 0x05, 0x0A]))
        #expect(starboard.shape == 5)
        #expect(!starboard.port)
        #expect(starboard.speedTenths == 122)
        #expect(starboard.volume == 5)
        #expect(!starboard.shifting)

        #expect(SurfFrame().data == template)
        #expect(SurfFrame(shape: 5, port: false, speedTenths: 122, volume: 5).data == Data([0x5D, 0x00, 0x7A, 0x00, 0x05, 0x0A]))

        let decoded = SurfFrame(bytes: Data([0x5D, 0x00, 0x7A, 0x00, 0x05, 0x0A]))
        #expect(decoded == SurfFrame(shape: 5, port: false, speedTenths: 122, volume: 5))
    }

    @Test func shortPayloadPadsWithTemplate() {
        #expect(SurfFrame(bytes: Data()).data == template)
        #expect(SurfFrame.length == 6)
        #expect(SurfFrame.shapeRange == 0...10)
        #expect(SurfFrame.volumeRange == 0...40)

        let partial = SurfFrame(bytes: Data([0x5D, 0x01, 0x7A]))
        #expect(partial.data == Data([0x5D, 0x01, 0x7A, 0x00, 0x07, 0x0A]))
        #expect(partial.shape == 5)
        #expect(!partial.port)
        #expect(partial.lights)
        #expect(partial.speedTenths == 122)
        #expect(partial.volume == 7)
        #expect(!partial.shifting)

        let extra = Data([0x45, 0x00, 0x79, 0x12, 0x07, 0x0A, 0xFF])
        #expect(SurfFrame(bytes: extra).data == Data([0x45, 0x00, 0x79, 0x12, 0x07, 0x0A]))
    }

    @Test func reservedBitsSurviveEdits() {
        var frame = SurfFrame(bytes: Data([0x47, 0xF0, 0x10, 0xAB, 0x03, 0xA0]))
        frame.shape = 9
        frame.port = false
        frame.lights = true
        frame.speedTenths = 100
        frame.volume = 12
        frame.shifting = true
        #expect(frame.data == Data([0x9D, 0xF1, 0x64, 0xAB, 0x0C, 0xA1]))

        let highVolume = SurfFrame(bytes: Data([0x45, 0x00, 0x79, 0x00, 0x32, 0x0A]))
        #expect(highVolume.volume == 50)
        #expect(highVolume.data[4] == 0x32)
    }

    @Test func applyingEachCommand() {
        let base = SurfFrame(bytes: Data([0x47, 0xF2, 0x79, 0xAB, 0x08, 0x0A]))

        let side = base.applying(.side(port: false))
        #expect(side.port == false)
        #expect(!side.shifting)
        #expect(side.shape == 4)
        #expect(side.speedTenths == 121)
        #expect(side.volume == 8)
        #expect(!side.lights)
        #expect(side.data == Data([0x4D, 0xF2, 0x79, 0xAB, 0x08, 0x0A]))
        #expect(base.applying(.side(port: true)).data == Data([0x45, 0xF2, 0x79, 0xAB, 0x08, 0x0A]))

        let speed = base.applying(.speed(tenths: 122))
        #expect(speed.speedTenths == 122)
        #expect(speed.data == Data([0x47, 0xF2, 0x7A, 0xAB, 0x08, 0x0A]))
        #expect(base.applying(.speed(tenths: 256)).speedTenths == 255)
        #expect(base.applying(.speed(tenths: -1)).speedTenths == 0)
        #expect(base.applying(.speed(tenths: 255)).data[2] == 255)

        let volume = base.applying(.volume(5))
        #expect(volume.volume == 5)
        #expect(volume.data == Data([0x47, 0xF2, 0x79, 0xAB, 0x05, 0x0A]))
        #expect(base.applying(.volume(41)).volume == 40)
        #expect(base.applying(.volume(-1)).volume == 0)
        #expect(base.applying(.volume(0)).data[4] == 0)
        #expect(base.applying(.volume(40)).data[4] == 40)

        let starboardShift = base.applying(.ballast(port: false, pounds: 200))
        #expect(starboardShift.shifting)
        #expect(starboardShift.port == base.port)
        #expect(!starboardShift.lights)
        #expect(starboardShift.volume == 8)
        #expect(starboardShift.data == Data([0x47, 0xF2, 0x79, 0xAB, 0x08, 0x0B]))

        let portShift = base.applying(.ballast(port: true, pounds: 350))
        #expect(portShift.shifting)
        #expect(portShift.port == base.port)
        #expect(portShift.data == Data([0x47, 0xF2, 0x79, 0xAB, 0x08, 0x0B]))

        let starboardBase = base.applying(.side(port: false))
        let portShiftOnStarboardWave = starboardBase.applying(.ballast(port: true, pounds: 150))
        #expect(portShiftOnStarboardWave.shifting)
        #expect(portShiftOnStarboardWave.port == false)
        #expect(portShiftOnStarboardWave.data == Data([0x4D, 0xF2, 0x79, 0xAB, 0x08, 0x0B]))

        let stopped = portShiftOnStarboardWave.applying(.stopBallast)
        #expect(!stopped.shifting)
        #expect(stopped.port == false)
        #expect(stopped.data == starboardBase.data)

        #expect(base.applying(.track(next: true)) == base)
        #expect(base.applying(.track(next: false)) == base)
        #expect(base.applying(.leaveWater) == base)
        #expect(portShift.applying(.leaveWater) == portShift)
        #expect(base.applying(.zoneVolume(id: 4, percent: 60)) == base)
        #expect(base.applying(.zoneStep(id: 4, up: true)) == base)
        #expect(base.applying(.refreshZones) == base)
    }

    @Test func boatStateUsesSideSpeedVolumeAndShifting() {
        let frame = SurfFrame(shape: 5, port: false, speedTenths: 122, volume: 5, lights: true, shifting: true)
        #expect(frame.boatState == BoatState(port: false, speedTenths: 122, volume: 5, shifting: true))
        #expect(frame.boatState.speedMph == 12.2)

        let decoded = SurfFrame(bytes: Data([0x5D, 0x01, 0x7A, 0x00, 0x05, 0x0B]))
        #expect(decoded.boatState == BoatState(port: false, speedTenths: 122, volume: 5, shifting: true))
        #expect(SurfFrame().boatState == BoatState(port: true, speedTenths: 121, volume: 7, shifting: false))
    }

    @Test func bluetoothLinkMatchesTheEsp32State() {
        let port = SurfFrame(bytes: Data([0x45, 0x00, 0x79, 0x00, 0x07, 0x0A]))
        #expect(port.linkData == Data([0x04, 0x00, 0x79, 0x07, 0x00]))
        #expect(SurfFrame(linkBytes: port.linkData) == SurfFrame(shape: 4, port: true, speedTenths: 121, volume: 7))

        let starboard = SurfFrame(bytes: Data([0x5D, 0x01, 0x7A, 0x00, 0x05, 0x0B]))
        #expect(starboard.linkData == Data([0x05, 0x01, 0x7A, 0x05, 0x03]))
        let decoded = SurfFrame(linkBytes: starboard.linkData)
        #expect(decoded.shape == 5)
        #expect(decoded.port == false)
        #expect(decoded.speedTenths == 122)
        #expect(decoded.volume == 5)
        #expect(decoded.lights == true)
        #expect(decoded.shifting == true)
    }

    @Test func commandDataEncodesThreeByteProtocol() {
        #expect(SurfFrame.commandMagic == 0xA5)

        #expect(SurfFrame.commandData(for: .side(port: true)) == Data([0xA5, 0x01, 0x01]))
        #expect(SurfFrame.commandData(for: .side(port: false)) == Data([0xA5, 0x01, 0x03]))

        #expect(SurfFrame.commandData(for: .speed(tenths: 123)) == Data([0xA5, 0x02, 123]))
        #expect(SurfFrame.commandData(for: .speed(tenths: -1)) == Data([0xA5, 0x02, 0]))
        #expect(SurfFrame.commandData(for: .speed(tenths: 300)) == Data([0xA5, 0x02, 255]))

        #expect(SurfFrame.commandData(for: .volume(9)) == Data([0xA5, 0x03, 9]))
        #expect(SurfFrame.commandData(for: .volume(-1)) == Data([0xA5, 0x03, 0]))
        #expect(SurfFrame.commandData(for: .volume(50)) == Data([0xA5, 0x03, 40]))

        #expect(SurfFrame.commandData(for: .shape(0)) == Data([0xA5, 0x04, 0]))
        #expect(SurfFrame.commandData(for: .shape(10)) == Data([0xA5, 0x04, 10]))
        #expect(SurfFrame.commandData(for: .shape(-3)) == Data([0xA5, 0x04, 0]))
        #expect(SurfFrame.commandData(for: .shape(99)) == Data([0xA5, 0x04, 10]))

        #expect(SurfFrame.ballastPoundsRange == 50...400)
        #expect(SurfFrame.ballastPoundsStep == 50)
        #expect(SurfFrame.commandData(for: .ballast(port: true)) == Data([0xA5, 0x05, 0x05]))
        #expect(SurfFrame.commandData(for: .ballast(port: false)) == Data([0xA5, 0x05, 0x06]))

        let expectedBallastTable: [(pounds: Int, portByte: UInt8, stbdByte: UInt8)] = [
            (50, 0x05, 0x06),
            (100, 0x09, 0x0A),
            (150, 0x0D, 0x0E),
            (200, 0x11, 0x12),
            (250, 0x15, 0x16),
            (300, 0x19, 0x1A),
            (350, 0x1D, 0x1E),
            (400, 0x21, 0x22),
        ]
        for entry in expectedBallastTable {
            #expect(SurfFrame.ballastCommandByte(port: true, pounds: entry.pounds) == entry.portByte)
            #expect(SurfFrame.ballastCommandByte(port: false, pounds: entry.pounds) == entry.stbdByte)
            #expect(SurfFrame.commandData(for: .ballast(port: true, pounds: entry.pounds)) == Data([0xA5, 0x05, entry.portByte]))
            #expect(SurfFrame.commandData(for: .ballast(port: false, pounds: entry.pounds)) == Data([0xA5, 0x05, entry.stbdByte]))
        }

        // Clamping and nearest-50 rounding on ballast pounds.
        #expect(SurfFrame.ballastCommandByte(port: true, pounds: -100) == 0x05)
        #expect(SurfFrame.ballastCommandByte(port: false, pounds: 0) == 0x06)
        #expect(SurfFrame.ballastCommandByte(port: true, pounds: 74) == 0x05)
        #expect(SurfFrame.ballastCommandByte(port: true, pounds: 75) == 0x09)
        #expect(SurfFrame.ballastCommandByte(port: true, pounds: 999) == 0x21)
        #expect(SurfFrame.ballastCommandByte(port: false, pounds: 999) == 0x22)

        #expect(StereoZone.level(fromPercent: 20) == 10)
        #expect(StereoZone.level(fromPercent: 22) == 11)
        #expect(StereoZone.percent(fromLevel: 10) == 20)
        #expect(StereoZone.percent(fromLevel: 11) == 22)
        #expect(StereoZone.percent(fromLevel: 50) == 100)
        #expect(SurfFrame.commandData(for: .zoneVolume(id: 1, percent: 10)) == Data([0xA5, 0x06, 0x01, 20]))
        #expect(SurfFrame.commandData(for: .zoneVolume(id: 4, percent: -10)) == Data([0xA5, 0x06, 0x04, 0]))
        #expect(SurfFrame.commandData(for: .zoneVolume(id: 4, percent: 150)) == Data([0xA5, 0x06, 0x04, 100]))

        #expect(SurfFrame.commandData(for: .zoneStep(id: 4, up: true)) == Data([0xA5, 0x07, 0x04, 0x00]))
        #expect(SurfFrame.commandData(for: .zoneStep(id: 2, up: false)) == Data([0xA5, 0x07, 0x02, 0x01]))

        #expect(SurfFrame.commandData(for: .refreshZones) == Data([0xA5, 0x08, 0x00]))
        #expect(SurfFrame.commandData(for: .stopBallast) == Data([0xA5, 0x09, 0x03]))
        #expect(SurfFrame.commandData(for: .track(next: true)) == Data([0xA5, 0x0A, 0x0B]))
        #expect(SurfFrame.commandData(for: .track(next: false)) == Data([0xA5, 0x0A, 0x0C]))

        #expect(SurfFrame.commandData(for: .leaveWater) == nil)
    }

    @Test func stereoZonesCodecRoundTripsAndValidates() {
        #expect(StereoZone.volumeRange == 0...50)
        #expect(StereoZone.stepSize == 1)

        let zones = [
            StereoZone(id: 1, name: "Bow", volume: 8, muted: false),
            StereoZone(id: 2, name: "Dash", volume: 16, muted: true),
            StereoZone(id: 3, name: "Cockpit", volume: 20, muted: false),
            StereoZone(id: 4, name: "Wake", volume: 32, muted: false),
        ]

        let encoded = StereoZone.encodeZones(zones)
        #expect(encoded[0] == 0x01)
        #expect(encoded[1] == 4)
        #expect(StereoZone.decodeZones(encoded) == zones)

        #expect(StereoZone.decodeZones(StereoZone.encodeZones([])) == [])

        // Empty name on the wire falls back to "Zone <id>".
        let unnamedWire = Data([0x01, 0x01, 0x03, 0x80 | 40, 0x00])
        #expect(StereoZone.decodeZones(unnamedWire) == [StereoZone(id: 3, name: "Zone 3", volume: 20, muted: true)])
        #expect(StereoZone(id: 2, name: "", volume: 120).name == "Zone 2")
        #expect(StereoZone(id: 2, name: "", volume: 120).volume == 50)

        // Malformed or truncated packets return nil.
        #expect(StereoZone.decodeZones(Data()) == nil)
        #expect(StereoZone.decodeZones(Data([0x01])) == nil)
        #expect(StereoZone.decodeZones(Data([0x02, 0x00])) == nil)
        #expect(StereoZone.decodeZones(Data([0x01, 0x09])) == nil)
        #expect(StereoZone.decodeZones(Data([0x01, 0x01, 0x01, 50])) == nil)
        #expect(StereoZone.decodeZones(Data([0x01, 0x01, 0x01, 50, 0x04, 0x42, 0x6F])) == nil)
        #expect(StereoZone.decodeZones(Data([0x01, 0x00, 0xFF])) == nil)
    }

    @Test func wakeZonePrefersWakeThenTowerThenLast() {
        #expect(StereoZone.wakeZone(in: []) == nil)

        let nmeaZones = [
            StereoZone(id: 1, name: "Bow", volume: 20),
            StereoZone(id: 2, name: "Dash", volume: 30),
            StereoZone(id: 3, name: "Cockpit", volume: 40),
            StereoZone(id: 4, name: "Wake", volume: 70),
        ]
        #expect(StereoZone.wakeZone(in: nmeaZones) == StereoZone(id: 4, name: "Wake", volume: 70))

        let wakeBeforeTower = [
            StereoZone(id: 1, name: "Tower", volume: 55),
            StereoZone(id: 2, name: "Wake Speakers", volume: 65),
            StereoZone(id: 3, name: "Subwoofer", volume: 45),
        ]
        #expect(StereoZone.wakeZone(in: wakeBeforeTower) == StereoZone(id: 2, name: "Wake Speakers", volume: 65))

        let towerOnly = [
            StereoZone(id: 1, name: "Bow", volume: 20),
            StereoZone(id: 2, name: "Tower Speakers", volume: 60),
            StereoZone(id: 3, name: "Subwoofer", volume: 50),
        ]
        #expect(StereoZone.wakeZone(in: towerOnly) == StereoZone(id: 2, name: "Tower Speakers", volume: 60))

        let genericZones = [
            StereoZone(id: 1, name: "Zone 1", volume: 20),
            StereoZone(id: 2, name: "Zone 2", volume: 35),
        ]
        #expect(StereoZone.wakeZone(in: genericZones) == StereoZone(id: 2, name: "Zone 2", volume: 35))
    }

    @MainActor
    @Test func disconnectedCentralDoesNotMutateFrame() {
        let central = BoatCentral()
        let initial = central.frame

        central.send(.side(port: false))
        #expect(central.frame == initial)

        central.send(.leaveWater)
        #expect(central.frame == initial)

        central.send(SurfFrame(shape: 8, port: false, speedTenths: 140, volume: 20))
        #expect(central.frame == initial)
    }

    @Test func bluetoothIdentifiers() {
        #expect(BoatBluetooth.localName == "iSurfSelect")
        #expect(BoatBluetooth.serviceUUID == CBUUID(string: "7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061"))
        #expect(BoatBluetooth.frameUUID == CBUUID(string: "7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061"))
        #expect(BoatBluetooth.commandUUID == CBUUID(string: "7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061"))
        #expect(BoatBluetooth.songUUID == CBUUID(string: "7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061"))
        #expect(BoatBluetooth.zonesUUID == CBUUID(string: "7c4e0005-6f3b-4a1e-9c55-1b2d3e4f5061"))
    }
}
