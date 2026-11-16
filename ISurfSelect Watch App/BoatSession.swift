import Combine
import CoreMotion
import HealthKit
import ISurfSelectCore
import WatchKit

/// Follows the watch's own water lock. On a watch with a depth sensor, submersion turns that lock on.
@MainActor
final class BoatSession: NSObject, ObservableObject {
    @Published var touchLocked = false
    @Published var preferWaterControls = false
    @Published var controller = CrownController(now: Date())
    @Published private(set) var status: BoatLinkStatus = .off
    @Published private(set) var shape = 4

    let central = BoatCentral()
    private var subscriptions = Set<AnyCancellable>()

    var showsCrown: Bool { touchLocked || preferWaterControls }
    var allowsExit: Bool { preferWaterControls && !touchLocked }

    var connectionText: String {
        switch status {
        case .off:
            "Not connected"
        case .scanning:
            "Searching"
        case .connecting:
            "Connecting"
        case .ready:
            "Connected"
        case .failed(let message):
            message.isEmpty ? "Not connected" : message
        }
    }

    override init() {
        super.init()
        central.$status.assign(to: &$status)
        central.$frame
            .dropFirst()
            .sink { [weak self] frame in
                self?.adopt(frame)
            }
            .store(in: &subscriptions)
    }

    private func adopt(_ frame: SurfFrame) {
        shape = frame.shape
        var next = controller
        next.adoptBoat(frame.boatState)
        guard next != controller else { return }
        controller = next
    }

    func setPrefersWater(_ on: Bool) {
        preferWaterControls = on
        var next = controller
        next.showList(at: Date())
        next.setAllowsExit(on && !touchLocked, at: Date())
        controller = next
        if on {
            beginWaterSession()
        } else {
            endWaterSession()
        }
    }

    func handle(_ command: BoatCommand) {
        if command == .leaveWater {
            setPrefersWater(false)
            return
        }
        central.send(command)
    }

    /// Action button: next function, or send when a speed or ballast change is waiting.
    func actionButton() {
        guard showsCrown else { return }
        var next = controller
        if let command = next.actionButton(at: Date()) {
            controller = next
            handle(command)
            WKInterfaceDevice.current().play(command == .leaveWater ? .click : .success)
        } else {
            controller = next
            WKInterfaceDevice.current().play(.click)
        }
    }

    private let store = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var runtime: WKExtendedRuntimeSession?
    private var submersion: CMWaterSubmersionManager?
    private var lockWhenWorkoutRuns = false
    private var polling = false

    /// Keeps iSurfSelect on screen and turns on Water Lock from inside the app.
    private func beginWaterSession() {
        guard runtime?.state != .running, runtime?.state != .scheduled else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        runtime = session
        session.start()
    }

    private func endWaterSession() {
        runtime?.invalidate()
        runtime = nil
        endWorkout()
    }

    private func endWorkout() {
        guard let workout else { return }
        if workout.state == .running || workout.state == .prepared {
            workout.end()
        }
        self.workout = nil
    }

    func start() async {
        central.start()
        let sharing: Set<HKSampleType> = [HKObjectType.workoutType()]
        try? await store.requestAuthorization(toShare: sharing, read: [])
        if CMWaterSubmersionManager.waterSubmersionAvailable {
            let manager = CMWaterSubmersionManager()
            manager.delegate = self
            submersion = manager
        }
        if ActionButtonBridge.consume() {
            actionButton()
        }
        guard !polling else { return }
        polling = true
        NotificationCenter.default.addObserver(
            forName: .surfActionButton,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ActionButtonBridge.consume()
                self.actionButton()
            }
        }
        while !Task.isCancelled {
            refreshLock()
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func refreshLock() {
        let locked = WKInterfaceDevice.current().isWaterLockEnabled
        guard locked != touchLocked else { return }
        if touchLocked && !locked {
            preferWaterControls = false
            endWaterSession()
        } else if locked {
            beginWaterSession()
        }
        var next = controller
        next.showList(at: Date())
        next.setAllowsExit(preferWaterControls && !locked, at: Date())
        controller = next
        touchLocked = locked
    }

    private func lockForWater() {
        lockWhenWorkoutRuns = true
        if workout?.state == .running {
            WKInterfaceDevice.current().enableWaterLock()
            refreshLock()
            return
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .surfingSports
        configuration.locationType = .outdoor
        guard let workout = try? HKWorkoutSession(healthStore: store, configuration: configuration) else {
            return
        }
        workout.delegate = self
        self.workout = workout
        workout.startActivity(with: Date())
    }
}

extension BoatSession: CMWaterSubmersionManagerDelegate {
    nonisolated func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        guard event.state == .submerged else { return }
        Task { @MainActor in
            lockForWater()
        }
    }

    nonisolated func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {
        // Watches without the depth entitlement or sensor keep working from Water Lock alone.
    }
}

extension BoatSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .running else { return }
        Task { @MainActor in
            guard lockWhenWorkoutRuns else { return }
            WKInterfaceDevice.current().enableWaterLock()
            refreshLock()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

extension BoatSession: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            if !WKInterfaceDevice.current().isWaterLockEnabled {
                lockForWater()
            }
            refreshLock()
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            runtime = nil
            if reason == .error {
                lockForWater()
                return
            }
            preferWaterControls = false
            endWorkout()
            refreshLock()
        }
    }
}
