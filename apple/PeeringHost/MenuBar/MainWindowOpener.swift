import AppKit
import MacCastKit
import SwiftUI

/// Brings the main window forward from outside a scene, where `openWindow` does not exist. When none is open, the app is asked to open its own `peering-host://` URL, which makes the `WindowGroup` create one; that needs nothing to have appeared first.
@MainActor
enum MainWindowOpener {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows
        let index = MainWindowChoice.index(
            of: MacCastHostApp.mainWindowID,
            identifiers: windows.map { $0.identifier?.rawValue },
            canBecomeMain: windows.map(\.canBecomeMain)
        )
        if let index {
            windows[index].makeKeyAndOrderFront(nil)
        } else {
            openThroughURL()
        }
    }

    /// Addressed to this bundle: another installed copy of the app would otherwise answer the URL.
    private static func openThroughURL() {
        guard let url = URL(string: "peering-host://setup") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A closure cannot sit in an environment entry without invalidating every reader on each update, so the action is
/// wrapped in an object that compares by identity. Only the main thread creates or calls it.
final class DismissMenuBar: Equatable, @unchecked Sendable {
    static let none = DismissMenuBar {}

    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    func callAsFunction() { action() }

    static func == (lhs: DismissMenuBar, rhs: DismissMenuBar) -> Bool { lhs === rhs }
}

extension EnvironmentValues {
    @Entry var dismissMenuBar: DismissMenuBar = .none
}
