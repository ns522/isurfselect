import ISurfSelectCore
import SwiftUI

/// One screen for the boat: the same ride commands as the watch, plus wave shape.
struct BoatControlScreen: View {
    @StateObject private var central = BoatCentral()
    @AppStorage("ballastPounds") private var ballastPounds = 50
    @State private var showFirmware = false

    private var frame: SurfFrame { central.frame }
    private var boat: BoatState { frame.boatState }
    private var snappedBallastPounds: Int { BoatState.snapBallastPounds(ballastPounds) }

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
                        if !central.zones.isEmpty {
                            zonesControl
                        }
                        ballastControl
                        shapeControl
                        firmwareCard
                    }
                    .padding(16)
                    .padding(.bottom, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.nautique)
        .onAppear { central.start() }
        .sheet(isPresented: $showFirmware) {
            FirmwareUpdateScreen(central: central)
        }
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
            .nautique
        case .ready:
            Color(red: 0.35, green: 0.9, blue: 0.5)
        case .failed:
            Color(red: 1, green: 0.38, blue: 0.32)
        }
    }

    private var liveFrame: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                trackButton("Prev", systemImage: "backward.end.fill", label: "Previous track") {
                    central.send(.track(next: false))
                }
                trackButton("Next", systemImage: "forward.end.fill", label: "Next track") {
                    central.send(.track(next: true))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private var zonesControl: some View {
        controlCard("Stereo Zones") {
            VStack(spacing: 16) {
                ForEach(central.zones) { zone in
                    StereoZoneControlRow(
                        zone: zone,
                        onStep: { up in
                            central.send(.zoneStep(id: zone.id, up: up))
                        },
                        onSetVolume: { percent in
                            central.send(.zoneVolume(id: zone.id, percent: percent))
                        }
                    )
                }
            }
        }
    }

    private var ballastControl: some View {
        controlCard("Ballast") {
            VStack(spacing: 12) {
                stepper(
                    value: "\(snappedBallastPounds)",
                    unit: "lbs",
                    canDecrease: snappedBallastPounds > SurfFrame.ballastPoundsRange.lowerBound,
                    canIncrease: snappedBallastPounds < SurfFrame.ballastPoundsRange.upperBound,
                    decreaseLabel: "Decrease ballast weight",
                    increaseLabel: "Increase ballast weight"
                ) { up in
                    changeBallastPounds(up: up)
                }

                HStack(spacing: 12) {
                    choice("Port", selected: false) {
                        central.send(.ballast(port: true, pounds: snappedBallastPounds))
                    }
                    .accessibilityLabel("Shift \(snappedBallastPounds) pounds ballast to port")
                    choice("Starboard", selected: false) {
                        central.send(.ballast(port: false, pounds: snappedBallastPounds))
                    }
                    .accessibilityLabel("Shift \(snappedBallastPounds) pounds ballast to starboard")
                }

                Button {
                    central.send(.stopBallast)
                } label: {
                    Label("Stop Pumps", systemImage: "stop.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(frame.shifting ? Color.white : Color(red: 1, green: 0.45, blue: 0.4))
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(
                            frame.shifting ? Color.red : Color.red.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    Color.red.opacity(frame.shifting ? 0 : 0.45),
                                    lineWidth: 1.5
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop ballast pumps")
            }
        }
    }

    private var firmwareCard: some View {
        controlCard("Firmware") {
            VStack(alignment: .leading, spacing: 12) {
                Text(firmwareSummary)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Update") { showFirmware = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private var firmwareSummary: String {
        switch central.status {
        case .ready:
            switch central.firmwareAvailability {
            case .unknown:
                "Checking the bridge…"
            case .unsupported:
                "This bridge needs a USB flash before it can take updates from the phone."
            case .available(let info):
                "Bridge \(info.version)"
            }
        default:
            "Connect to the bridge to install firmware."
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

    private func trackButton(
        _ title: String,
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(
                    Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(
                    selected ? Color.nautique : Color.white.opacity(0.14),
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

    private func changeBallastPounds(up: Bool) {
        let delta = up ? SurfFrame.ballastPoundsStep : -SurfFrame.ballastPoundsStep
        let next = BoatState.snapBallastPounds(snappedBallastPounds + delta)
        guard next != snappedBallastPounds else { return }
        ballastPounds = next
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

private struct StereoZoneControlRow: View {
    let zone: StereoZone
    let onStep: (Bool) -> Void
    let onSetVolume: (Int) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var lastDragSend: Date = .distantPast
    @State private var lastSentPercent: Int?

    private var displayedPercent: Int {
        isDragging ? Self.quantize(dragValue) : zone.volume
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isDragging ? dragValue : Double(zone.volume) },
            set: { newValue in
                dragValue = newValue
                let pct = Self.quantize(newValue)
                if isDragging {
                    let now = Date()
                    if pct != lastSentPercent, now.timeIntervalSince(lastDragSend) >= 0.12 {
                        lastDragSend = now
                        lastSentPercent = pct
                        onSetVolume(pct)
                    }
                } else if pct != zone.volume {
                    onSetVolume(pct)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(zone.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(displayedPercent)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(zone.muted ? .white.opacity(0.45) : .white)
            }

            HStack(spacing: 10) {
                compactStepButton("−", label: "Decrease \(zone.name) volume") {
                    onStep(false)
                }

                Slider(
                    value: sliderBinding,
                    in: Double(StereoZone.volumeRange.lowerBound)...Double(StereoZone.volumeRange.upperBound),
                    step: Double(StereoZone.stepSize)
                ) {
                    Text(zone.name)
                } onEditingChanged: { editing in
                    if editing {
                        if !isDragging {
                            dragValue = Double(zone.volume)
                            lastSentPercent = zone.volume
                        }
                        isDragging = true
                    } else {
                        let finalPercent = Self.quantize(dragValue)
                        isDragging = false
                        if finalPercent != zone.volume || finalPercent != lastSentPercent {
                            onSetVolume(finalPercent)
                        }
                        lastSentPercent = nil
                    }
                }
                .tint(.nautique)
                .accessibilityLabel("\(zone.name) volume")
                .accessibilityValue("\(displayedPercent)")

                compactStepButton("+", label: "Increase \(zone.name) volume") {
                    onStep(true)
                }
            }
        }
    }

    private func compactStepButton(
        _ title: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private static func quantize(_ raw: Double) -> Int {
        let stepped = Int((raw / Double(StereoZone.stepSize)).rounded()) * StereoZone.stepSize
        return min(max(stepped, StereoZone.volumeRange.lowerBound), StereoZone.volumeRange.upperBound)
    }
}

#Preview {
    BoatControlScreen()
}
