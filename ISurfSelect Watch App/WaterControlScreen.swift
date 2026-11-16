import ISurfSelectCore
import SwiftUI
import WatchKit

/// Crown-only screen. Turn to move through the list. Pause one second, then turn to change that item.
struct WaterControlScreen: View {
    @Binding var controller: CrownController
    var allowsExit: Bool
    var usesActionButton: Bool
    var connection: String
    var connected: Bool
    var onCommand: (BoatCommand) -> Void
    @AppStorage("sideCountdown") private var sideCountdown = true
    @AppStorage("ballastPounds") private var ballastPounds = 50
    @State private var crown = 0.0
    @State private var now = Date()
    @State private var countdown: Int?
    @State private var sideFeedback: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            Text(connection)
                .font(.caption.weight(.bold))
                .foregroundStyle(controller.phase == .browsing ? (connected ? Color.green : Color.nautique) : Color.black)
            if controller.phase == .browsing {
                Text(controller.currentFunctionTitle)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                Text(countdown.map(String.init) ?? controller.valueText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(countdown == nil ? Color.secondary : Color.nautique)
            } else {
                Text(phaseTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                Text(countdown.map(String.init) ?? controller.valueText)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.black)
                if !controller.unitText.isEmpty {
                    Text(controller.unitText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.7))
                }
            }
            Text(statusLine)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(controller.phase == .browsing ? Color.secondary : Color.black.opacity(0.75))
            menuDots
            if allowsExit {
                Button("On boat") {
                    onCommand(.leaveWater)
                    WKInterfaceDevice.current().play(.click)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else {
                Text("Hold the crown to unlock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .focusable(true)
        .digitalCrownRotation(
            $crown,
            from: -10_000,
            through: 10_000,
            by: 1,
            sensitivity: .low,
            isContinuous: true,
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crown) { _, nextValue in
            var next = controller
            let before = next.function
            let moment = Date()
            if let command = next.turnInWater(offset: nextValue, at: moment) {
                onCommand(command)
                if case .side = command {
                    playSideChange()
                } else {
                    WKInterfaceDevice.current().play(command == .leaveWater ? .click : .success)
                }
            } else if next.sideChangeBlocked {
                WKInterfaceDevice.current().play(.failure)
            } else if next.function != before {
                WKInterfaceDevice.current().play(.click)
            }
            controller = next
        }
        .onAppear {
            applyExitFlag()
            syncBallastPounds(ballastPounds)
        }
        .onChange(of: allowsExit) { _, _ in applyExitFlag() }
        .onChange(of: ballastPounds) { _, newValue in syncBallastPounds(newValue) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                now = Date()
                var next = controller
                next.settle(at: now)
                controller = next
            }
        }
    }

    private func playSideChange() {
        sideFeedback?.cancel()
        let counted = sideCountdown
        sideFeedback = Task {
            if counted {
                for mark in [3, 2, 1] {
                    countdown = mark
                    WKInterfaceDevice.current().play(.notification)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                countdown = nil
            } else {
                countdown = nil
                let end = Date().addingTimeInterval(3)
                while Date() < end {
                    if Task.isCancelled { return }
                    WKInterfaceDevice.current().play(.click)
                    try? await Task.sleep(for: .milliseconds(160))
                }
            }
        }
    }

    private var menuDots: some View {
        HStack(spacing: 5) {
            ForEach(controller.menu, id: \.rawValue) { item in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(dotColor(selected: item == controller.function))
            }
        }
        .padding(.top, 6)
    }

    private func dotColor(selected: Bool) -> Color {
        let ink: Color = controller.phase == .browsing ? .white : .black
        return selected ? ink : ink.opacity(0.35)
    }

    private func applyExitFlag() {
        var next = controller
        next.setAllowsExit(allowsExit, at: Date())
        controller = next
    }

    private func syncBallastPounds(_ pounds: Int) {
        let snapped = BoatState.snapBallastPounds(pounds)
        if controller.boat.ballastPounds != snapped {
            var next = controller
            next.setBallastPounds(snapped)
            controller = next
        }
    }

    private var statusLine: String {
        let remaining = controller.sideCooldownRemaining(at: now)
        if controller.function == .side, controller.phase != .browsing, remaining > 0 {
            return "Wave locked \(Int(ceil(remaining)))s"
        }
        if usesActionButton, controller.phase == .browsing {
            return "Turn to switch. Action: next."
        }
        return controller.hint
    }

    private var phaseTitle: String {
        switch controller.phase {
        case .browsing: controller.currentFunctionTitle
        case .armed: "ARMED"
        case .confirming: "CONFIRM"
        }
    }

    private var background: Color {
        switch controller.phase {
        case .browsing: .black
        case .armed: .nautique
        case .confirming: .yellow
        }
    }
}
