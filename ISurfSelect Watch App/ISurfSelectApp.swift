import ISurfSelectCore
import SwiftUI
import WatchKit

@main
struct ISurfSelectApp: App {
    @StateObject private var session = BoatSession()
    @AppStorage("ballastPounds") private var ballastPounds = 50

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
                            song: session.song,
                            shifting: session.shifting,
                            onCommand: session.handle
                        )
                    }
                }
            }
            .onAppear {
                session.setBallastPounds(ballastPounds)
            }
            .onChange(of: ballastPounds) { _, newValue in
                session.setBallastPounds(newValue)
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
