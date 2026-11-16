import Foundation
import Testing
@testable import SurfSelectCore

struct CrownControllerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func browsingMovesOneRowPerClick() {
        var controller = CrownController(now: start)

        let command = controller.rotate(up: false, at: start.addingTimeInterval(0.2))

        #expect(command == nil)
        #expect(controller.function == .speed)
        #expect(controller.phase == .browsing)
    }

    @Test func browsingStopsAtTheEnds() {
        var controller = CrownController(now: start)

        _ = controller.rotate(up: true, at: start.addingTimeInterval(0.1))
        #expect(controller.function == .side)

        for step in 0..<4 {
            _ = controller.rotate(up: false, at: start.addingTimeInterval(0.2 + Double(step) * 0.05))
        }
        #expect(controller.function == .ballast)
    }

    @Test func liveBoatReplacesTheDisplayUntilAChangeIsWaiting() {
        var controller = CrownController(now: start, boat: BoatState(port: true, speedTenths: 110, volume: 8))
        controller.adoptBoat(BoatState(port: false, speedTenths: 150, volume: 12))
        #expect(controller.boat == BoatState(port: false, speedTenths: 150, volume: 12))
        #expect(controller.phase == .browsing)

        var confirming = armed(at: .speed, boat: BoatState(port: false, speedTenths: 150, volume: 12))
        _ = confirming.rotate(up: true, at: start.addingTimeInterval(10.2))
        #expect(confirming.phase == .confirming)
        confirming.adoptBoat(BoatState(port: true, speedTenths: 80, volume: 1))
        #expect(confirming.boat.speedTenths == 150)
        #expect(confirming.phase == .confirming)
    }

    @Test func quietSecondArmsTheRow() {
        var controller = CrownController(now: start)

        controller.settle(at: start.addingTimeInterval(1.9))
        #expect(controller.phase == .browsing)

        controller.settle(at: start.addingTimeInterval(2))
        #expect(controller.phase == .armed)
        #expect(controller.function == .side)
    }

    @Test func armedSideSendsOnTheFirstClick() {
        var controller = armed(at: .side)

        let first = controller.rotate(up: true, at: start.addingTimeInterval(10.2))
        #expect(first == nil)
        #expect(controller.boat.port == true)
        #expect(controller.phase == .confirming)
        #expect(controller.valueText == "STBD")

        let command = controller.rotate(up: true, at: start.addingTimeInterval(10.4))
        #expect(command == .side(port: false))
        #expect(controller.boat.port == false)
        #expect(controller.phase == .armed)
    }

    @Test func speedWaitsForASecondClick() {
        var controller = armed(at: .speed)

        let first = controller.rotate(up: true, at: start.addingTimeInterval(10.2))
        #expect(first == nil)
        #expect(controller.phase == .confirming)
        #expect(controller.boat.speedTenths == 110)
        #expect(controller.valueText == "11.1")

        let second = controller.rotate(up: true, at: start.addingTimeInterval(10.4))
        #expect(second == .speed(tenths: 111))
        #expect(controller.boat.speedTenths == 111)
        #expect(controller.phase == .armed)
    }

    @Test func oppositeClickCancelsAPendingSpeedChange() {
        var controller = armed(at: .speed)
        _ = controller.rotate(up: true, at: start.addingTimeInterval(10.2))

        let command = controller.rotate(up: false, at: start.addingTimeInterval(10.4))

        #expect(command == nil)
        #expect(controller.boat.speedTenths == 110)
        #expect(controller.phase == .armed)
        #expect(controller.valueText == "11.0")
    }

    @Test func quietSecondDropsAnUnconfirmedChange() {
        var controller = armed(at: .ballast)
        _ = controller.rotate(up: false, at: start.addingTimeInterval(10.2))
        #expect(controller.valueText == "PORT")

        controller.settle(at: start.addingTimeInterval(12.2))

        #expect(controller.phase == .browsing)
        #expect(controller.pendingDirection == nil)
    }

    @Test func quietSecondLeavesAnArmedRow() {
        var controller = armed(at: .volume)

        controller.settle(at: start.addingTimeInterval(12))

        #expect(controller.phase == .browsing)
        #expect(controller.function == .volume)
    }

    @Test func volumeSendsImmediatelyAndStopsAtTheEnds() {
        var controller = armed(at: .volume, boat: BoatState(volume: 40))

        let command = controller.rotate(up: true, at: start.addingTimeInterval(10.2))

        #expect(command == nil)
        #expect(controller.boat.volume == 40)

        let lower = controller.rotate(up: false, at: start.addingTimeInterval(10.4))
        #expect(lower == .volume(39))
    }

    @Test func doneRowAppearsOnlyWhenExitIsAllowed() {
        var controller = CrownController(now: start)
        for step in 0..<5 {
            _ = controller.rotate(up: false, at: start.addingTimeInterval(Double(step + 1) * 0.05))
        }
        #expect(controller.function == .ballast)

        controller.setAllowsExit(true, at: start.addingTimeInterval(1))
        _ = controller.rotate(up: false, at: start.addingTimeInterval(1.1))
        #expect(controller.function == .onBoat)
        controller.settle(at: start.addingTimeInterval(10))

        let command = controller.rotate(up: true, at: start.addingTimeInterval(10.2))
        #expect(command == .leaveWater)
    }

    @Test func actionButtonMovesToTheNextFunctionAndArmsIt() {
        var controller = CrownController(now: start)

        let command = controller.actionButton(at: start.addingTimeInterval(0.2))

        #expect(command == nil)
        #expect(controller.function == .speed)
        #expect(controller.phase == .browsing)
    }

    @Test func aSpinThenTheOtherWayChangesFunctionWithoutSending() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)

        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(0.4))

        #expect(controller.function == .speed)
        #expect(controller.boat.port == true)
        #expect(controller.finishSpin(at: start.addingTimeInterval(0.5)) == nil)
    }

    @Test func stoppingAfterASpinSwitchesTheWave() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)

        #expect(controller.finishSpin(at: start.addingTimeInterval(0.2)) == .side(port: false))
        #expect(controller.function == .side)
    }

    @Test func aSmallWaterTurnDoesNothing() {
        var controller = CrownController(now: start)
        _ = controller.turnInWater(offset: 0, at: start)
        #expect(controller.turnInWater(offset: 4, at: start.addingTimeInterval(0.2)) == nil)
        #expect(controller.function == .side)
        #expect(controller.phase == .browsing)
    }

    @Test func aDeliberateWaterTurnMovesOneRow() {
        var controller = CrownController(now: start)
        _ = controller.turnInWater(offset: 0, at: start)
        #expect(controller.turnInWater(offset: -7, at: start.addingTimeInterval(0.2)) == nil)
        #expect(controller.function == .side)

        #expect(controller.turnInWater(offset: -8, at: start.addingTimeInterval(0.4)) == nil)
        #expect(controller.function == .speed)
    }

    @Test func reversingAWaterTurnStartsOver() {
        var controller = CrownController(now: start)
        _ = controller.turnInWater(offset: 0, at: start)
        _ = controller.turnInWater(offset: 6, at: start.addingTimeInterval(0.2))
        _ = controller.turnInWater(offset: 0, at: start.addingTimeInterval(0.4))
        #expect(controller.function == .side)
    }

    @Test func aShortNudgeDoesNotSend() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 1, at: start)

        #expect(controller.finishSpin(at: start.addingTimeInterval(0.2)) == nil)
        #expect(controller.boat.port == true)
    }

    @Test func oneSpinMovesOnlyOneMenuItem() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)
        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(0.2))
        #expect(controller.function == .speed)

        _ = controller.turnOffWave(offset: 0, at: start.addingTimeInterval(1))
        _ = controller.turnOffWave(offset: -8, at: start.addingTimeInterval(1.2))

        #expect(controller.function == .volume)
        #expect(controller.phase == .browsing)
    }

    @Test func offTheWaveTheOneSecondFlashArmsTheSetting() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)
        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(0.2))
        #expect(controller.function == .speed)
        #expect(controller.phase == .browsing)

        controller.settle(at: start.addingTimeInterval(2.1))
        #expect(controller.phase == .browsing)
        controller.settle(at: start.addingTimeInterval(2.2))
        #expect(controller.phase == .armed)
        #expect(controller.function == .speed)

        let changed = controller.rotate(up: true, at: start.addingTimeInterval(1.4))
        #expect(changed == nil)
        #expect(controller.phase == .confirming)

        #expect(controller.rideHome(at: start.addingTimeInterval(6.3)) == false)
        #expect(controller.rideHome(at: start.addingTimeInterval(6.4)) == true)
        #expect(controller.function == .side)
    }

    @Test func theCrownReturnsToTheWaveAfterFiveQuietSeconds() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)
        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(0.3))
        #expect(controller.function == .speed)

        #expect(controller.rideHome(at: start.addingTimeInterval(5.2)) == false)
        #expect(controller.rideHome(at: start.addingTimeInterval(5.3)) == true)
        #expect(controller.function == .side)
    }

    @Test func waveSideWaitsTenSecondsBeforeSwitchingAgain() {
        var controller = CrownController(now: start)
        controller.spin(up: true, detents: 3, at: start)
        #expect(controller.finishSpin(at: start.addingTimeInterval(0.2)) == .side(port: false))

        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(1))
        #expect(controller.finishSpin(at: start.addingTimeInterval(1.2)) == nil)
        #expect(controller.boat.port == false)
        #expect(controller.sideChangeBlocked)

        controller.spin(up: false, detents: 3, at: start.addingTimeInterval(10.4))
        #expect(controller.finishSpin(at: start.addingTimeInterval(10.6)) == .side(port: true))
    }

    @Test func dryControlsSendImmediately() {
        var controller = CrownController(now: start)
        controller.settle(at: start.addingTimeInterval(1))

        let side = controller.setSide(port: false, at: start.addingTimeInterval(2))
        let speed = controller.changeSpeed(up: true, at: start.addingTimeInterval(2))
        let volume = controller.changeVolume(up: false, at: start.addingTimeInterval(2))
        let ballast = controller.shiftBallast(port: true, at: start.addingTimeInterval(2))

        #expect(side == .side(port: false))
        #expect(speed == .speed(tenths: 111))
        #expect(volume == .volume(7))
        #expect(ballast == .ballast(port: true))
        #expect(controller.phase == .browsing)
    }

    @Test func drySetSideAlwaysSendsEvenWhenSideAlreadyMatches() {
        var controller = CrownController(now: start)
        #expect(controller.boat.port == true)

        // Re-tapping the already-selected Port button still emits a command.
        let samePort = controller.setSide(port: true, at: start.addingTimeInterval(1))
        #expect(samePort == .side(port: true))
        #expect(controller.boat.port == true)

        // Switching to Starboard and immediately re-tapping Starboard (e.g. dropped BLE packet) still sends.
        let firstStarboard = controller.setSide(port: false, at: start.addingTimeInterval(2))
        let secondStarboard = controller.setSide(port: false, at: start.addingTimeInterval(3))
        #expect(firstStarboard == .side(port: false))
        #expect(secondStarboard == .side(port: false))
        #expect(controller.boat.port == false)
        #expect(!controller.sideChangeBlocked)
        #expect(controller.sideCooldownRemaining(at: start.addingTimeInterval(5)) == 8)

        // Water-mode crown gestures still ignore spinning toward the already-active side.
        controller.spin(up: true, detents: 3, at: start.addingTimeInterval(20))
        #expect(controller.finishSpin(at: start.addingTimeInterval(20.2)) == nil)
        #expect(controller.boat.port == false)
    }

    @Test func ballastSendsPortOrStarboardOnTheConfirmingClick() {
        var controller = armed(at: .ballast)
        _ = controller.rotate(up: false, at: start.addingTimeInterval(10.2))

        let command = controller.rotate(up: false, at: start.addingTimeInterval(10.4))

        #expect(command == .ballast(port: true))
        #expect(controller.phase == .armed)
    }

    private func armed(
        at function: BoatFunction,
        boat: BoatState = BoatState()
    ) -> CrownController {
        var controller = CrownController(now: start, boat: boat)
        for step in 0..<function.rawValue {
            _ = controller.rotate(up: false, at: start.addingTimeInterval(Double(step) * 0.05))
        }
        controller.settle(at: start.addingTimeInterval(10))
        return controller
    }
}
