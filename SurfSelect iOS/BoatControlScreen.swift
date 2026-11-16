import SurfSelectCore
import SwiftUI

/// One screen for the boat: the same ride commands as the watch, plus wave shape.
struct BoatControlScreen: View {
    @StateObject private var central = BoatCentral()

    private var frame: SurfFrame { central.frame }
    private var boat: BoatState { frame.boatState }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                statusHeader
                ScrollView {
                    VStack(spacing: 14) {
                        liveFrame
                        sideControl
                        speedControl
                        volumeControl
                        ballastControl
                        shapeControl
                    }
                    .padding(16)
                    .padding(.bottom, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onAppear { central.start() }
    }

    private var statusHeader: some View {
        Text(statusText)
            .font(.title2.weight(.bold))
            .foregroundStyle(statusColor)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(statusColor.opacity(0.16))
            .accessibilityLabel("Connection")
            .accessibilityValue(statusText)
    }

    private var statusText: String {
        switch central.status {
        case .off:
            "Off"
        case .scanning:
            "Searching for \(BoatBluetooth.localName)"
        case .connecting:
            "Connecting"
        case .ready:
            "Connected"
        case .failed(let message):
            message.isEmpty ? "Failed" : message
        }
    }

    private var statusColor: Color {
        switch central.status {
        case .off:
            Color.white.opacity(0.72)
        case .scanning, .connecting:
            .orange
        case .ready:
            Color(red: 0.35, green: 0.9, blue: 0.5)
        case .failed:
            Color(red: 1, green: 0.38, blue: 0.32)
        }
    }

    private var liveFrame: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 14
            ) {
                readout("Side", boat.port ? "Port" : "Starboard")
                readout("Speed", String(format: "%.1f mph", boat.speedMph))
                readout("Shape", "\(frame.shape)")
                readout("Volume", "\(boat.volume)")
                readout("Shift", frame.shifting ? "Running" : "Idle")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Song")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(central.song.isEmpty ? "—" : central.song)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sideControl: some View {
        controlCard("Side") {
            HStack(spacing: 12) {
                choice("Port", selected: boat.port) {
                    central.send(.side(port: true))
                }
                choice("Starboard", selected: !boat.port) {
                    central.send(.side(port: false))
                }
            }
        }
    }

    private var speedControl: some View {
        controlCard("Speed") {
            stepper(
                value: String(format: "%.1f", boat.speedMph),
                unit: "mph",
                canDecrease: canStep(boat.speedTenths, up: false, range: CrownController.speedRange),
                canIncrease: canStep(boat.speedTenths, up: true, range: CrownController.speedRange),
                decreaseLabel: "Decrease speed",
                increaseLabel: "Increase speed"
            ) { up in
                changeSpeed(up: up)
            }
        }
    }

    private var volumeControl: some View {
        controlCard("Volume") {
            stepper(
                value: "\(boat.volume)",
                unit: "",
                canDecrease: canStep(boat.volume, up: false, range: CrownController.volumeRange),
                canIncrease: canStep(boat.volume, up: true, range: CrownController.volumeRange),
                decreaseLabel: "Decrease volume",
                increaseLabel: "Increase volume"
            ) { up in
                changeVolume(up: up)
            }
        }
    }

    private var ballastControl: some View {
        controlCard("Ballast") {
            HStack(spacing: 12) {
                choice("Port", selected: false) {
                    central.send(.ballast(port: true))
                }
                .accessibilityLabel("Shift ballast to port")
                choice("Starboard", selected: false) {
                    central.send(.ballast(port: false))
                }
                .accessibilityLabel("Shift ballast to starboard")
            }
        }
    }

    private var shapeControl: some View {
        controlCard("Shape") {
            stepper(
                value: "\(frame.shape)",
                unit: "",
                canDecrease: canStep(frame.shape, up: false, range: SurfFrame.shapeRange),
                canIncrease: canStep(frame.shape, up: true, range: SurfFrame.shapeRange),
                decreaseLabel: "Decrease shape",
                increaseLabel: "Increase shape"
            ) { up in
                changeShape(up: up)
            }
        }
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(
                    selected ? Color.orange : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepper(
        value: String,
        unit: String,
        canDecrease: Bool,
        canIncrease: Bool,
        decreaseLabel: String,
        increaseLabel: String,
        change: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            stepButton("−", label: decreaseLabel, enabled: canDecrease) { change(false) }
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            stepButton("+", label: increaseLabel, enabled: canIncrease) { change(true) }
        }
    }

    private func stepButton(_ title: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 40, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func changeSpeed(up: Bool) {
        guard let next = step(boat.speedTenths, up: up, range: CrownController.speedRange) else { return }
        central.send(.speed(tenths: next))
    }

    private func changeVolume(up: Bool) {
        guard let next = step(boat.volume, up: up, range: CrownController.volumeRange) else { return }
        central.send(.volume(next))
    }

    private func changeShape(up: Bool) {
        guard let next = step(frame.shape, up: up, range: SurfFrame.shapeRange) else { return }
        central.send(.shape(next))
    }

    private func canStep(_ value: Int, up: Bool, range: ClosedRange<Int>) -> Bool {
        step(value, up: up, range: range) != nil
    }

    /// One step inside `range`. A value outside the range snaps to the nearest end.
    private func step(_ value: Int, up: Bool, range: ClosedRange<Int>) -> Int? {
        let next = value + (up ? 1 : -1)
        if range.contains(next) { return next }
        if up, value < range.lowerBound { return range.lowerBound }
        if !up, value > range.upperBound { return range.upperBound }
        return nil
    }
}

#Preview {
    BoatControlScreen()
}
