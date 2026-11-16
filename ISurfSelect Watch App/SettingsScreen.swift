import SwiftUI
import WatchKit

struct SettingsScreen: View {
    @Binding var waterControls: Bool
    @AppStorage("sideCountdown") private var sideCountdown = true

    private var isUltra: Bool {
        WKInterfaceDevice.current().waterResistanceRating == .wr100
    }

    var body: some View {
        List {
            Toggle("Water controls", isOn: $waterControls)
            Toggle("Side countdown", isOn: $sideCountdown)
            note("Side countdown taps once a second for three seconds after a wave change in the water. Turn it off for one steady three-second vibration instead.")
            note("Turns on Water Lock and keeps iSurfSelect on the screen. Hold the crown until it says Unlocked to leave. Don’t turn Water Lock on from Control Center, or the watch returns to the clock and the crown can’t open this app.")
            if isUltra {
                note("Set the Action Button to the iSurfSelect shortcut Next control. That button moves to the next function. When a speed or ballast change is waiting, it sends it.")
            }
        }
        .navigationTitle("Settings")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
    }
}
