import AppIntents
import Foundation

extension Notification.Name {
    static let surfActionButton = Notification.Name("isurfselect.action-button")
}

enum ActionButtonBridge {
    private static let lock = NSLock()
    private static var pending = false

    static func post() {
        lock.lock()
        pending = true
        lock.unlock()
        NotificationCenter.default.post(name: .surfActionButton, object: nil)
    }

    static func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasPending = pending
        pending = false
        return wasPending
    }
}

struct AdvanceSurfControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Surf Control"
    static var description = IntentDescription("Moves iSurfSelect to the next control, or sends a speed or ballast change that is waiting.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        ActionButtonBridge.post()
        return .result()
    }
}

@available(watchOS 26.0, *)
extension AdvanceSurfControlIntent {
    static var supportedModes: IntentModes { .foreground(.immediate) }
}

struct ISurfSelectShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AdvanceSurfControlIntent(),
            phrases: ["Next control in \(.applicationName)"],
            shortTitle: "Next control",
            systemImageName: "arrow.right.circle"
        )
    }
}
