import ISurfSelectCore
import SwiftUI
import WatchKit

/// Touch controls for use on the boat, while the screen is dry.
struct DryControlScreen: View {
    @Binding var controller: CrownController
    @Binding var waterControls: Bool
    var connection: String
    var connected: Bool
    var shape: Int
    var onCommand: (BoatCommand) -> Void
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(connection)
                    .font(.headline)
                    .foregroundStyle(connected ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                summary

                controlCard("Side") {
                    HStack(spacing: 6) {
                        choice("PORT", selected: controller.boat.port) {
                            send { $0.setSide(port: true, at: Date()) }
                        }
                        choice("STBD", selected: !controller.boat.port) {
                            send { $0.setSide(port: false, at: Date()) }
                        }
                    }
                    let remaining = controller.sideCooldownRemaining(at: now)
                    if remaining > 0 {
                        Text("Wave locked \(Int(ceil(remaining)))s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                controlCard("Speed") {
                    stepper(
                        value: String(format: "%.1f", controller.boat.speedMph),
                        unit: "mph",
                        valueAbove: true
                    ) { up in
                        send { $0.changeSpeed(up: up, at: Date()) }
                    }
                }

                controlCard("Volume") {
                    stepper(value: "\(controller.boat.volume)", unit: "") { up in
                        send { $0.changeVolume(up: up, at: Date()) }
                    }
                }

                controlCard("Shape") {
                    stepper(value: "\(shape)", unit: "") { up in
                        send { _ in
                            let next = shape + (up ? 1 : -1)
                            guard SurfFrame.shapeRange.contains(next) else { return nil }
                            return .shape(next)
                        }
                    }
                }

                controlCard("Ballast") {
                    HStack(spacing: 6) {
                        shift("Port") { send { $0.shiftBallast(port: true, at: Date()) } }
                        shift("Stbd") { send { $0.shiftBallast(port: false, at: Date()) } }
                    }
                }

                NavigationLink {
                    SettingsScreen(waterControls: $waterControls)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Surf")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(controller.boat.port ? "Port" : "Starboard")
                Spacer()
                Text(String(format: "%.1f mph", controller.boat.speedMph))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func controlCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(selected ? .orange : Color.white.opacity(0.16))
            .frame(maxWidth: .infinity)
    }

    private func shift(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stepper(
        value: String,
        unit: String,
        valueAbove: Bool = false,
        change: @escaping (Bool) -> Void
    ) -> some View {
        let readout = VStack(spacing: 0) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        let controls = HStack {
            Button { change(false) } label: {
                Image(systemName: "minus")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            Button { change(true) } label: {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
        }
        if valueAbove {
            VStack(spacing: 6) {
                readout
                controls
            }
        } else {
            HStack {
                Button { change(false) } label: {
                    Image(systemName: "minus")
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 4)
                readout
                Spacer(minLength: 4)
                Button { change(true) } label: {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func send(_ update: (inout CrownController) -> BoatCommand?) {
        var next = controller
        let command = update(&next)
        controller = next
        if let command {
            onCommand(command)
            WKInterfaceDevice.current().play(.click)
        } else if next.sideChangeBlocked {
            WKInterfaceDevice.current().play(.failure)
        }
    }
}
