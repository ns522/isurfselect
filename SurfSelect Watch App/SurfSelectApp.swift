import SurfSelectCore
import SwiftUI
import WatchKit

@main
struct SurfSelectApp: App {
    @StateObject private var session = BoatSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.showsCrown {
                    WaterControlScreen(
                        controller: $session.controller,
                        allowsExit: session.allowsExit,
                        usesActionButton: WKInterfaceDevice.current().waterResistanceRating == .wr100,
                        connection: session.connectionText,
                        connected: session.status == .ready,
                        onCommand: session.handle
                    )
                } else {
                    NavigationStack {
                        DryControlScreen(
                            controller: $session.controller,
                            waterControls: waterControls,
                            connection: session.connectionText,
                            connected: session.status == .ready,
                            shape: session.shape,
                            onCommand: session.handle
                        )
                    }
                }
            }
            .task {
                await session.start()
            }
        }
    }

    private var waterControls: Binding<Bool> {
        Binding(
            get: { session.preferWaterControls },
            set: { session.setPrefersWater($0) }
        )
    }
}
