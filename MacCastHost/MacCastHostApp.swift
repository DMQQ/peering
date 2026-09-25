import AppKit
import MacCastKit
import SwiftUI

/// The app's own delegate, for the one hook a scene cannot be trusted with.
///
/// **Why the termination hook is here and no longer on the window.** It used to be an `onReceive`
/// on the window's content view, which exists only while the window does. This is a menu bar app
/// that is usually left with its window closed, and the Mac that has to be put back to sleeping
/// normally is exactly that one, so the hook had to move somewhere that does not depend on a view
/// being alive. `applicationWillTerminate` is delivered to the delegate whether or not a window
/// was ever opened, and it is the last moment before the process goes in which the lid-close
/// restore can run.
///
/// The model is owned here rather than by the scene for the same reason: it has to exist on a Mac
/// nobody has looked at, because the launch check inside it is the crash path.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let model = HostModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the model is used for anything: a crash in the launch path is the one this is for,
        // and this is the earliest point the delegate is given.
        CrashLog.install(subject: "host")

        Task { @MainActor [model] in
            // ScreenCaptureKit is the authoritative permission check and it is asynchronous.
            // Wait for that answer before deciding whether setup must interrupt the user.
            while !model.permissions.hasCompletedInitialCheck {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !model.permissions.allRequiredGranted else { return }

            // A menu-bar app remembers that its window was closed. That is useful after setup,
            // but fatal during setup: the permissions are mandatory and a hidden explanation
            // leaves only an amber menu icon. Reuse the restored window when SwiftUI made one;
            // otherwise route a URL back into the WindowGroup so it creates one.
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else if let url = URL(string: "peering-host://setup") {
                NSWorkspace.shared.open(url)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }
}

@main
struct MacCastHostApp: App {
    /// The window is reopened from the menu bar, which needs something to name it by once the
    /// user has closed it — closing a window must not take the host down with it.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    /// Owned by the app rather than by a screen, for the same reason the model is: the daily check
    /// has to run whether or not anybody has opened the window, and this is usually a Mac that
    /// nobody is sitting in front of.
    @State private var updater = Updater()

    private var model: HostModel { appDelegate.model }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            HostRootView()
                .environment(model)
                .environment(updater)
                .onOpenURL { model.handleWidgetCommand($0) }
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

/// Keeps setup in front of the product until macOS has granted both capabilities Peering needs.
/// Permission state, rather than a one-time "onboarding seen" flag, owns this decision so a
/// revoked grant cannot leave the host presenting controls that silently do nothing.
private struct HostRootView: View {
    @Environment(HostModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// Whether this Mac has been shown the away-from-home switches before. Persisted rather than
    /// re-derived from permission state, since it is a step in its own right — skippable, and
    /// meant only once, not every time permissions happen to be re-checked.
    @AppStorage("pl.dmq.peering.host.hasSeenAwaySwitchesOnboarding") private var hasSeenAwaySwitchesOnboarding = false

    /// Whether this Mac has finished (or skipped) the "pair your first iPhone" step. Also set the
    /// moment a device actually connects — see `FirstConnectionOnboardingView` — so a Mac that
    /// gets paired without anyone clicking Done still exits onboarding.
    @AppStorage("pl.dmq.peering.host.hasSeenFirstConnectionOnboarding") private var hasSeenFirstConnectionOnboarding = false

    private var ready: Bool { model.permissions.allRequiredGranted }

    var body: some View {
        Group {
            if !model.permissions.hasCompletedInitialCheck {
                PermissionCheckView()
            } else if !ready {
                PermissionOnboardingView()
                    .transition(.opacity)
            } else if !hasSeenAwaySwitchesOnboarding {
                AwaySwitchesOnboardingView(onContinue: { hasSeenAwaySwitchesOnboarding = true })
                    .transition(.opacity)
            } else if !hasSeenFirstConnectionOnboarding {
                FirstConnectionOnboardingView(onContinue: { hasSeenFirstConnectionOnboarding = true })
                    .transition(.opacity)
            } else {
                HostStatusView()
                    .transition(.opacity)
            }
        }
        .animation(HostMotion.state, value: ready)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.permissions.refresh()
        }
        .onChange(of: ready) { wasReady, isReady in
            if wasReady, !isReady { model.stop() }
        }
    }
}

private struct PermissionCheckView: View {
    var body: some View {
        ZStack {
            HostPalette.backdrop.ignoresSafeArea()
            HostPalette.stageLight.ignoresSafeArea()
            ProgressView("Checking Mac access…")
                .controlSize(.small)
                .foregroundStyle(HostPalette.muted)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}
