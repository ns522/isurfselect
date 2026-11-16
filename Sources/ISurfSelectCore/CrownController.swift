import Foundation

public enum BoatFunction: Int, CaseIterable, Sendable {
    case side
    case speed
    case volume
    case wake
    case track
    case ballast
    case onBoat

    public var title: String {
        switch self {
        case .side: "Side"
        case .speed: "Speed"
        case .volume: "Volume"
        case .wake: "Wake"
        case .track: "Track"
        case .ballast: "Ballast"
        case .onBoat: "Done"
        }
    }

    /// Speed and ballast change the boat's attitude. They send on a second click.
    public var needsConfirm: Bool {
        switch self {
        case .volume, .wake, .track, .onBoat: false
        case .side: true
        case .speed, .ballast: true
        }
    }
}

public enum ControlPhase: Equatable, Sendable {
    case browsing
    case armed
    case confirming
}

public struct BoatState: Equatable, Sendable {
    public var port: Bool
    /// Speed in tenths of a mile per hour. 110 is 11.0 mph.
    public var speedTenths: Int
    public var volume: Int
    public var shifting: Bool
    public var ballastPounds: Int
    public var wakeZoneID: Int?
    public var wakeZoneName: String
    public var wakeVolume: Int

    public init(
        port: Bool = true,
        speedTenths: Int = 110,
        volume: Int = 8,
        shifting: Bool = false,
        ballastPounds: Int = 50,
        wakeZoneID: Int? = nil,
        wakeZoneName: String = "Wake",
        wakeVolume: Int = 0
    ) {
        self.port = port
        self.speedTenths = speedTenths
        self.volume = volume
        self.shifting = shifting
        self.ballastPounds = Self.snapBallastPounds(ballastPounds)
        self.wakeZoneID = wakeZoneID
        self.wakeZoneName = wakeZoneName
        self.wakeVolume = wakeVolume
    }

    public static func snapBallastPounds(_ pounds: Int) -> Int {
        let clamped = min(max(pounds, 0), SurfFrame.ballastPoundsRange.upperBound)
        return min(
            max(((clamped + 25) / SurfFrame.ballastPoundsStep) * SurfFrame.ballastPoundsStep, SurfFrame.ballastPoundsRange.lowerBound),
            SurfFrame.ballastPoundsRange.upperBound
        )
    }

    public var speedMph: Double { Double(speedTenths) / 10 }
}

public enum BoatCommand: Equatable, Sendable {
    case side(port: Bool)
    case speed(tenths: Int)
    case volume(Int)
    case shape(Int)
    case ballast(port: Bool, pounds: Int = 50)
    case stopBallast
    case track(next: Bool)
    case zoneVolume(id: Int, percent: Int)
    case zoneStep(id: Int, up: Bool)
    case refreshZones
    case leaveWater
}

public struct CrownController: Equatable, Sendable {
    public static let speedRange = 80...250
    public static let volumeRange = 0...40
    public static let dwell: TimeInterval = 2
    /// Detents in one direction that count as a spin, not a single click.
    public static let spinDistance: Double = 3
    /// Water-mode crown travel, in detents, before one click counts. Small bumps stay ignored.
    public static let waterDetents: Double = 8
    /// Quiet time before the crown returns to the wave.
    public static let rideHomeDelay: TimeInterval = 5
    /// Minimum time between wave-side changes.
    public static let sideCooldown: TimeInterval = 10

    public private(set) var function: BoatFunction
    public private(set) var phase: ControlPhase
    public private(set) var boat: BoatState
    public private(set) var pendingDirection: Int?
    public private(set) var allowsExit = false
    public private(set) var sideChangeBlocked = false

    public var menu: [BoatFunction] {
        BoatFunction.allCases.filter { item in
            if item == .wake, boat.wakeZoneID == nil { return false }
            if item == .onBoat, !allowsExit { return false }
            return true
        }
    }

    public var currentFunctionTitle: String {
        if function == .wake, !boat.wakeZoneName.isEmpty {
            return boat.wakeZoneName
        }
        return function.title
    }

    /// The Done row is only offered when water controls were turned on by hand.
    public mutating func setAllowsExit(_ allows: Bool, at time: Date) {
        allowsExit = allows
        if !allows, function == .onBoat {
            function = .ballast
            showList(at: time)
        }
    }

    private var lastEvent: Date
    private var lastActivity: Date
    private var lastSideChange: Date?
    private var lastCrownOffset: Double?
    private var spinDirection: Int?
    private var spinTravel: Double = 0
    private var spinArmed: Int?
    private var reverseTravel: Double = 0
    private var menuTravel: Double = 0
    private var waterTravel: Double = 0
    private var waterMoved: Date?

    public init(now: Date, boat: BoatState = BoatState()) {
        function = .side
        phase = .browsing
        self.boat = boat
        pendingDirection = nil
        lastEvent = now
        lastActivity = now
    }

    /// Copies a live boat frame onto the display. A confirming gesture keeps its pending value.
    public mutating func adoptBoat(_ state: BoatState) {
        guard phase != .confirming else { return }
        let savedPounds = boat.ballastPounds
        boat = state
        boat.ballastPounds = savedPounds
        if boat.wakeZoneID == nil, function == .wake {
            function = .volume
            phase = .browsing
            pendingDirection = nil
        }
    }

    public mutating func setBallastPounds(_ pounds: Int) {
        boat.ballastPounds = BoatState.snapBallastPounds(pounds)
    }

    /// Drops any armed or unconfirmed crown gesture and shows the function list.
    public mutating func showList(at time: Date) {
        phase = .browsing
        pendingDirection = nil
        lastEvent = time
    }

    public mutating func setSide(port: Bool, at time: Date) -> BoatCommand? {
        sideChangeBlocked = false
        showList(at: time)
        return changeSide(to: port, at: time, enforceCooldown: false)
    }

    public func sideCooldownRemaining(at time: Date) -> TimeInterval {
        guard let lastSideChange else { return 0 }
        return max(0, Self.sideCooldown - time.timeIntervalSince(lastSideChange))
    }

    public mutating func changeSpeed(up: Bool, at time: Date) -> BoatCommand? {
        showList(at: time)
        let next = snapped(boat.speedTenths + (up ? 1 : -1), in: Self.speedRange)
        guard next != boat.speedTenths else { return nil }
        boat.speedTenths = next
        return .speed(tenths: next)
    }

    public mutating func changeVolume(up: Bool, at time: Date) -> BoatCommand? {
        showList(at: time)
        let next = snapped(boat.volume + (up ? 1 : -1), in: Self.volumeRange)
        guard next != boat.volume else { return nil }
        boat.volume = next
        return .volume(next)
    }

    public mutating func changeWakeVolume(up: Bool, at time: Date) -> BoatCommand? {
        showList(at: time)
        return stepWake(up: up)
    }

    public mutating func shiftBallast(port: Bool, pounds: Int? = nil, at time: Date) -> BoatCommand {
        showList(at: time)
        let resolved = BoatState.snapBallastPounds(pounds ?? boat.ballastPounds)
        boat.shifting = true
        return .ballast(port: port, pounds: resolved)
    }

    public mutating func stopBallast(at time: Date) -> BoatCommand {
        showList(at: time)
        boat.shifting = false
        return .stopBallast
    }

    public mutating func skipTrack(next: Bool, at time: Date) -> BoatCommand {
        showList(at: time)
        return .track(next: next)
    }

    /// Moves to the next function, or sends a speed or ballast change that is waiting.
    public mutating func actionButton(at time: Date) -> BoatCommand? {
        resetSpin()
        lastEvent = time
        lastActivity = time
        if phase == .confirming, let pendingDirection {
            return commit(pendingDirection)
        }
        pendingDirection = nil
        if function == .onBoat {
            return .leaveWater
        }
        stepSelection(-1, wrap: true)
        phase = .browsing
        return nil
    }

    /// Crown turns on Speed, Volume, or Ballast. One quiet second arms the row.
    public mutating func turnOffWave(offset: Double, at time: Date) -> BoatCommand? {
        defer { lastCrownOffset = offset }
        guard function != .side, let lastCrownOffset else { return nil }
        let steps = Int((offset - lastCrownOffset).rounded())
        guard steps != 0 else { return nil }
        let sign = steps > 0 ? 1.0 : -1.0
        if menuTravel != 0, (menuTravel > 0) != (sign > 0) {
            menuTravel = 0
        }
        menuTravel += Double(steps)
        guard abs(menuTravel) >= Self.spinDistance else { return nil }
        menuTravel = 0
        lastEvent = time
        lastActivity = time
        let up = sign > 0
        switch phase {
        case .browsing:
            stepSelection(up ? 1 : -1)
            if function == .side {
                phase = .armed
            }
            return nil
        case .armed:
            return adjust(up ? 1 : -1)
        case .confirming:
            if pendingDirection == (up ? 1 : -1) {
                return commit(up ? 1 : -1)
            }
            phase = .browsing
            pendingDirection = nil
            stepSelection(up ? 1 : -1)
            return nil
        }
    }

    /// Follows the crown. A full spin one way, then a full spin the other way, changes function.
    public mutating func trackCrown(offset: Double, at time: Date) {
        defer { lastCrownOffset = offset }
        guard let lastCrownOffset else { return }
        let steps = Int((offset - lastCrownOffset).rounded())
        guard steps != 0 else { return }
        let sign = steps > 0 ? 1 : -1
        for _ in 0..<abs(steps) {
            let before = function
            addSpinStep(sign, at: time)
            if function != before { break }
        }
    }

    /// Sends the spin when the crown stops, unless it was reversed into a function change.
    public mutating func finishSpin(at time: Date) -> BoatCommand? {
        lastEvent = time
        let armed = spinArmed
        let reversed = reverseTravel > 0
        resetSpin()
        guard let armed, !reversed else { return nil }
        sideChangeBlocked = false
        phase = .armed
        pendingDirection = nil
        return sendRide(armed)
    }

    /// Test helper. `detents` is how far the crown traveled in that direction.
    public mutating func spin(up: Bool, detents: Int, at time: Date) {
        let sign = up ? 1 : -1
        for _ in 0..<detents {
            addSpinStep(sign, at: time)
        }
    }

    /// Returns to the wave after five quiet seconds.
    public mutating func rideHome(at time: Date) -> Bool {
        guard function != .side else { return false }
        guard spinArmed == nil, spinDirection == nil else { return false }
        guard time.timeIntervalSince(lastActivity) >= Self.rideHomeDelay else { return false }
        function = .side
        phase = .armed
        pendingDirection = nil
        lastEvent = time
        lastActivity = time
        return true
    }

    public var rideHint: String {
        if function == .side {
            return "Spin to switch the wave. Spin back for next."
        }
        return "Spin between settings. Pause one second, then spin."
    }

    /// Water crown. A bump shorter than `waterDetents` does nothing. A continued turn
    /// in one direction counts as one click each time that distance is reached.
    public mutating func turnInWater(offset: Double, at time: Date) -> BoatCommand? {
        defer { lastCrownOffset = offset }
        guard let lastCrownOffset else { return nil }
        let delta = offset - lastCrownOffset
        guard delta != 0 else { return nil }
        if waterTravel != 0, (waterTravel > 0) != (delta > 0) {
            waterTravel = 0
        }
        waterTravel += delta
        waterMoved = time
        let clicks = Int(abs(waterTravel) / Self.waterDetents)
        guard clicks > 0 else { return nil }
        let up = waterTravel > 0
        waterTravel -= Double(clicks) * (up ? Self.waterDetents : -Self.waterDetents)
        var sent: BoatCommand?
        for _ in 0..<clicks {
            if let command = rotate(up: up, at: time) {
                sent = command
            }
        }
        return sent
    }

    /// Positive crown rotation is `up`. The view calls `settle` on a short timer.
    public mutating func rotate(up: Bool, at time: Date) -> BoatCommand? {
        lastEvent = time
        lastActivity = time
        let direction = up ? 1 : -1
        switch phase {
        case .browsing:
            stepSelection(direction)
            return nil
        case .armed:
            return adjust(direction)
        case .confirming:
            guard pendingDirection == direction else {
                phase = .armed
                pendingDirection = nil
                return nil
            }
            return commit(direction)
        }
    }

    /// Moves browsing to armed, and armed or confirming back to browsing, after one quiet second.
    public mutating func settle(at time: Date) {
        if let waterMoved, time.timeIntervalSince(waterMoved) >= 0.8 {
            waterTravel = 0
            self.waterMoved = nil
        }
        guard time.timeIntervalSince(lastEvent) >= Self.dwell else { return }
        switch phase {
        case .browsing:
            phase = .armed
        case .armed, .confirming:
            phase = .browsing
            pendingDirection = nil
        }
        lastEvent = time
    }

    public var valueText: String {
        switch function {
        case .side:
            displayedPort ? "PORT" : "STBD"
        case .speed:
            String(format: "%.1f", Double(displayedSpeedTenths) / 10)
        case .volume:
            "\(displayedVolume)"
        case .wake:
            "\(displayedWakeVolume)"
        case .track:
            "SKIP"
        case .ballast:
            if boat.shifting {
                "STOP"
            } else if phase == .confirming {
                (pendingDirection ?? 0) > 0 ? "STBD" : "PORT"
            } else {
                "\(boat.ballastPounds)"
            }
        case .onBoat:
            "BOAT"
        }
    }

    public var unitText: String {
        switch function {
        case .speed:
            "MPH"
        case .volume:
            "VOL"
        case .wake:
            "VOL"
        case .track:
            "NEXT / PREV"
        case .ballast:
            if boat.shifting {
                "PUMPS"
            } else if phase == .confirming {
                "\(boat.ballastPounds) LB"
            } else {
                "LB"
            }
        case .side, .onBoat:
            ""
        }
    }

    public var hint: String {
        switch (function, phase) {
        case (.onBoat, .armed), (.onBoat, .confirming):
            "Turn to go back"
        case (.ballast, .armed) where boat.shifting:
            "Turn to stop"
        case (_, .browsing):
            "Turn to switch"
        case (_, .armed):
            function.needsConfirm ? "Turn, then confirm" : "Turn to send"
        case (_, .confirming):
            "Turn again to send"
        }
    }

    private var displayedPort: Bool {
        if function == .side, phase == .confirming {
            return (pendingDirection ?? 0) < 0
        }
        return boat.port
    }

    private var displayedSpeedTenths: Int {
        guard function == .speed, phase == .confirming, let pendingDirection else {
            return boat.speedTenths
        }
        return snapped(boat.speedTenths + pendingDirection, in: Self.speedRange)
    }

    private var displayedVolume: Int {
        guard function == .volume, phase == .confirming, let pendingDirection else {
            return boat.volume
        }
        return snapped(boat.volume + pendingDirection, in: Self.volumeRange)
    }

    private var displayedWakeVolume: Int {
        snapped(boat.wakeVolume, in: StereoZone.volumeRange)
    }

    private mutating func addSpinStep(_ sign: Int, at time: Date) {
        lastEvent = time
        lastActivity = time
        if let spinArmed {
            if sign == spinArmed {
                reverseTravel = 0
                return
            }
            reverseTravel += 1
            if reverseTravel >= Self.spinDistance {
                stepSelection(-1, wrap: true)
                phase = .browsing
                pendingDirection = nil
                resetSpin()
            }
            return
        }
        if spinDirection != sign {
            spinDirection = sign
            spinTravel = 1
        } else {
            spinTravel += 1
        }
        if spinTravel >= Self.spinDistance {
            spinArmed = sign
        }
    }

    private mutating func resetSpin() {
        spinDirection = nil
        spinTravel = 0
        spinArmed = nil
        reverseTravel = 0
        menuTravel = 0
    }

    private mutating func changeSide(to port: Bool, at time: Date, enforceCooldown: Bool = true) -> BoatCommand? {
        if enforceCooldown {
            if let lastSideChange, time.timeIntervalSince(lastSideChange) < Self.sideCooldown {
                sideChangeBlocked = true
                return nil
            }
            guard boat.port != port else { return nil }
        }
        boat.port = port
        lastSideChange = time
        return .side(port: port)
    }

    private mutating func stepSelection(_ direction: Int, wrap: Bool = false) {
        let items = menu
        guard !items.isEmpty else { return }
        let index = items.firstIndex(of: function) ?? 0
        let raw = index - direction
        let next = wrap
            ? (raw % items.count + items.count) % items.count
            : min(max(raw, 0), items.count - 1)
        function = items[next]
    }

    private mutating func stepWake(up: Bool) -> BoatCommand? {
        guard let wakeID = boat.wakeZoneID else { return nil }
        let delta = up ? StereoZone.stepSize : -StereoZone.stepSize
        boat.wakeVolume = snapped(boat.wakeVolume + delta, in: StereoZone.volumeRange)
        return .zoneStep(id: wakeID, up: up)
    }

    private mutating func sendRide(_ direction: Int) -> BoatCommand? {
        switch function {
        case .side:
            return changeSide(to: direction < 0, at: lastEvent)
        case .volume:
            let next = snapped(boat.volume + direction, in: Self.volumeRange)
            guard next != boat.volume else { return nil }
            boat.volume = next
            return .volume(next)
        case .wake:
            return stepWake(up: direction > 0)
        case .track:
            return .track(next: direction > 0)
        case .speed:
            let next = snapped(boat.speedTenths + direction, in: Self.speedRange)
            guard next != boat.speedTenths else { return nil }
            boat.speedTenths = next
            return .speed(tenths: next)
        case .ballast:
            if boat.shifting {
                boat.shifting = false
                return .stopBallast
            }
            boat.shifting = true
            return .ballast(port: direction < 0, pounds: boat.ballastPounds)
        case .onBoat:
            return .leaveWater
        }
    }

    private mutating func adjust(_ direction: Int) -> BoatCommand? {
        switch function {
        case .side:
            let port = direction < 0
            guard boat.port != port else { return nil }
            phase = .confirming
            pendingDirection = direction
            return nil
        case .volume:
            let next = snapped(boat.volume + direction, in: Self.volumeRange)
            guard next != boat.volume else { return nil }
            boat.volume = next
            return .volume(next)
        case .wake:
            return stepWake(up: direction > 0)
        case .track:
            return .track(next: direction > 0)
        case .speed:
            let candidate = snapped(boat.speedTenths + direction, in: Self.speedRange)
            guard candidate != boat.speedTenths else { return nil }
            phase = .confirming
            pendingDirection = direction
            return nil
        case .ballast:
            if boat.shifting {
                boat.shifting = false
                phase = .armed
                pendingDirection = nil
                return .stopBallast
            }
            phase = .confirming
            pendingDirection = direction
            return nil
        case .onBoat:
            return .leaveWater
        }
    }

    private mutating func commit(_ direction: Int) -> BoatCommand? {
        phase = .armed
        pendingDirection = nil
        switch function {
        case .speed:
            let next = snapped(boat.speedTenths + direction, in: Self.speedRange)
            guard next != boat.speedTenths else { return nil }
            boat.speedTenths = next
            return .speed(tenths: next)
        case .ballast:
            if boat.shifting {
                boat.shifting = false
                return .stopBallast
            }
            boat.shifting = true
            return .ballast(port: direction < 0, pounds: boat.ballastPounds)
        case .side:
            return changeSide(to: direction < 0, at: lastEvent)
        case .volume, .wake, .track, .onBoat:
            return nil
        }
    }

    private func snapped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
