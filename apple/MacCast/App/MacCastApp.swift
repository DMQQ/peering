import MacCastKit
import os
import UserNotifications
import RemoteCore
import SwiftUI
import UIKit

private let linkLog = Logger(subsystem: "pl.dmq.peering", category: "links")

// Singleton so the AppDelegate and any view can agree on the current allowed orientations.
final class OrientationLock {
    static let shared = OrientationLock()
    private init() {}
    var allowed: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad
        ? .all
        : .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.allowed
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        SessionNotifier.shared.remoteTokenDidChange(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Remote push is the only way a Mac reaches this phone with no session up, and the error is the only evidence of why that never happens, so it is kept.
        SessionNotifier.shared.remoteTokenDidFail(error)
        Analytics.pushRegistrationFailed(error)
    }
}

@main
struct MacCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned here, not by a view: a connection outlives any screen, and a model created by `HostPickerView` would be destroyed when the picker left the hierarchy, which is when the connection starts being used.
    @State private var model = MacCastApp.makeModel()
    /// Owned here also because an intent has no view hierarchy and "open a shell on prod" arrives before any screen exists.
    @State private var servers = SSHModel()
    @State private var quickCommands = QuickCommands()
    @State private var router = URLCommandRouter()
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = false

    @Environment(\.scenePhase) private var scenePhase

    init() {
        PostHogConfiguration.setup()
        Analytics.observeSettings()

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "Peering.clearDelivered") {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        #endif
        // First, before any view exists: the crash file must exist before the crash and the last run's report must be filed before this run's can overwrite it. A handler installed later would miss a crash on launch.
        CrashLog.install(subject: "phone")
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        AgentApprovalNotifier.shared.registerCategories()
    }

    /// The pin store is read when the model is built, which happens before `init` runs, so the alarm is wired here.
    private static func makeModel() -> SessionModel {
        PinStoreAlarm.install { status in Task { @MainActor in Analytics.pinStoreUnreadable(status: status) } }
        return SessionModel()
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { router.confirming != nil }, set: { if !$0 { router.confirming = nil } })
    }

    var body: some Scene {
        WindowGroup {
            SecuredRootView(onLockChange: { router.setLocked($0, model: model, servers: servers) }) {
                ContentView()
            }
                .alert(router.confirmationTitle, isPresented: confirmingBinding) {
                    Button("End", role: .destructive) { router.confirm(model: model, servers: servers) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(router.confirmationMessage)
                }
                // Sideways, a screen may only move if it has somewhere to go: iOS bounces a vertical scroll view on both axes. `.basedOnSize` rather than `.never` so the tour's pages and the terminal, which scroll sideways, keep it. On the root because the value travels through the environment to every scroll view, sheets included.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .environment(model)
                .environment(servers)
                .environment(quickCommands)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.memoryWarningReceived()
                    servers.trimMemory()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                    model.powerStateChanged()
                }
                .task {
                    for await _ in NotificationCenter.default.notifications(
                        named: SessionNotifier.remoteTokenChangedName
                    ) {
                        model.sendPushToken()
                    }
                }
                .task {
                    model.start()
                    await model.storeManager.start()
                    // Handed over once so Siri and Shortcuts have something to reach: intents cannot read a view hierarchy (see ``IntentHost``).
                    IntentHost.model = model
                    IntentHost.servers = servers
                    SessionPiP.shared.onActiveChanged = { active in
                        model.pictureInPictureChanged(active: active)
                    }
                    NotificationRoute.deliverPending()
                    // Browsing triggers the local network permission prompt. Defer it until
                    // after the welcome flow so a first-run user sees onboarding first.
                    if hasSeenWelcome {
                        model.startBrowsing()
                    }
                    TerminalActivity.shared.adoptOrphan()
                    AgentChatActivity.shared.adoptOrphan()
                }
                // Coming back to the front ends the banners' relevance: a pairing prompt from last night is a claim about the past.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        CrashLog.setForeground(true)
                        SessionPiP.shared.stop()
                        SessionNotifier.shared.retractAll()
                        model.enteringForeground()
                        Analytics.appOpened(plan: model.storeManager.access.plan)
                    case .inactive:
                        model.leavingForeground()
                    case .background:
                        CrashLog.setForeground(false)
                        model.leavingForeground()
                        // The few seconds iOS grants before suspending: the session still ends when that runs out (``SessionModel/backgroundTimeExpired()``), but tidy, with the Mac told and the Live Activity taken down.
                        model.enteringBackground()
                    default:
                        break
                    }
                }
                // The widget cannot connect anything itself, since the session, identity and sockets live in this process, so it hands over with one instruction. Live Activity buttons use the same channel.
                .onOpenURL { url in
                    if PairingPayload.isHostLink(url) {
                        let hostID: String
                        do {
                            hostID = try PairingPayload.hostID(from: url.absoluteString)
                        } catch {
                            linkLog.error("Ignored a Mac link that does not parse: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        model.openHostLink(hostID: hostID)
                        return
                    }
                    router.handle(url, model: model, servers: servers)
                }
                .preferredColorScheme(.dark)
        }
    }
}
