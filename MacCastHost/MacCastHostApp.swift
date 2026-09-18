import SwiftUI

@main
struct MacCastHostApp: App {
    /// The window is reopened from the menu bar, which needs something to name it by once the
    /// user has closed it — closing a window must not take the host down with it.
    static let mainWindowID = "main"

    @State private var model = HostModel()
    /// Owned by the app rather than by a screen, for the same reason the model is: the daily check
    /// has to run whether or not anybody has opened the window, and this is usually a Mac that
    /// nobody is sitting in front of.
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            HostStatusView()
                .environment(model)
                .environment(updater)
                .onOpenURL { model.handleWidgetCommand($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.prepareForTermination()
                }
                // Dark by fiat, not by preference. The palette is fixed rather than semantic —
                // see `HostPalette` — so the appearance has to be pinned too, or every control
                // the system draws for us (fields, toggles, segmented pickers, sheets, the
                // confirmation dialog) would come back in the Mac's own appearance and land
                // light-on-dark in a window that is otherwise near black.
                //
                // It also means this host looks the same on the Mac of whoever installed it,
                // which is the point: the phone beside it does not have a light mode either.
                .preferredColorScheme(.dark)
        }
        // Opens on a window worth having: the picture, the way in, and the devices under it all
        // in one look, rather than the minimum the layout survives at. macOS remembers whatever
        // the window is dragged to afterwards, so this is the first impression and not a rule.
        .defaultSize(width: 1200, height: 870)
        .windowResizability(.contentSize)

        // The connection state is read here rather than inside the label because an
        // `@Observable` read in a scene body is what invalidates the scene.
        MenuBarExtra {
            HostMenuBarContent()
                .environment(model)
        } label: {
            HostMenuBarLabel(state: model.menuBarState)
        }
        .menuBarExtraStyle(.menu)

        // The standard place for it, in the app menu under About. Sparkle's own driver puts up the
        // window; all this does is offer the verb.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }
                    .disabled(!updater.canCheck)
            }
        }
    }
}
