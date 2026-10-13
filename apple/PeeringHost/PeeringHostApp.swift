import AppKit
import PeeringKit
import SwiftUI

/// The app's own delegate, for the one hook a scene cannot be trusted with.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let model = HostModel()
    let updater = Updater()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureHostHooks.install(
            failure: { Analytics.failed($0, in: .capture) },
            encoderRestarted: { HostSessionFacts.shared.noteEncoderRestart() }
        )
        menuBar = MenuBarController(model: model, updater: updater)
        PostHogConfiguration.setup()
        Analytics.observeSettings()
        Analytics.hostLaunched()

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
            // leaves only an amber menu icon.
            MainWindowOpener.show()
        }
    }

    /// Waits for the cards' end events to leave, bounded by the publisher's own timeout, so quitting does not strand a Lock Screen card.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = model.endLiveActivitiesForTermination {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return waiting ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }
}

@main
struct PeeringHostApp: App {
    /// The window is reopened from the menu bar, which needs something to name it by once the
    /// user has closed it — closing a window must not take the host down with it.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    private var updater: Updater { appDelegate.updater }

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
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 870)
        .windowResizability(.contentSize)

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
