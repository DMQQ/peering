import AppKit
import SwiftUI

/// Opens the main window from outside a scene. `openWindow` only exists inside one, so the
/// main `WindowGroup` hands its copy over through `captureOpenWindow()`.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    private var openWindow: (() -> Void)?

    func capture(_ action: @escaping () -> Void) {
        openWindow = action
    }

    func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow()
        } else if let url = URL(string: "peering-host://setup") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct CaptureOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowOpener.shared.capture { openWindow(id: MacCastHostApp.mainWindowID) }
        }
    }
}

extension View {
    func captureOpenWindow() -> some View { modifier(CaptureOpenWindow()) }
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
