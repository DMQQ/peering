import Foundation
import MacCastKit
import PostHog
import os
import UIKit

/// Anonymous usage counts, on by default and off with one switch in Settings.
///
/// Never sent by these explicit events: a Mac's name or address, a file name, a command, anything typed or shown, or the id the relay meters by.
/// Every value is from a closed set (an enum or a bool), so nothing the user typed can reach an event by accident.
enum Analytics {
    private static let lastOpenKey = "Peering.analyticsLastOpen"
    /// A foreground within this of the last one is the same sitting, not a new open.
    private static let openGap: TimeInterval = 30 * 60

    /// What every `feature_used` carries, so a count can be read by connection and plan: set where a session starts and the plan is read, cleared where the session ends.
    private struct Context {
        var path: String?
        var plan: String?
        var tab: Screen?
        var pushed: Screen?
    }

    private static let context = OSAllocatedUnfairLock(initialState: Context())

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.analyticsEnabled) as? Bool ?? true
    }

    static func appOpened(plan: RelayPlan?) {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastOpenKey)
        guard now - last > openGap else { return }
        UserDefaults.standard.set(now, forKey: lastOpenKey)
        context.withLock { $0.plan = plan?.rawValue }
        send("app_opened", ["plan": plan?.rawValue ?? "unknown"])
    }

    static func sessionStarted(path: String, plan: RelayPlan?) {
        context.withLock { $0.path = path; $0.plan = plan?.rawValue }
        send("session_started", ["path": path, "plan": plan?.rawValue ?? "unknown"])
    }

    static func pairingDecided(accepted: Bool) {
        send(accepted ? "pairing_accepted" : "pairing_declined", [:])
    }

    static func sessionEnded(path: String) {
        context.withLock { $0.path = nil }
        send("session_ended", ["path": path])
    }

    static func onboardingCompleted() {
        send("onboarding_completed", [:])
    }

    static func onboardingSkipped(atPage page: Int) {
        send("onboarding_skipped", ["page": String(page)])
    }

    static func onboardingPage(_ page: Int) {
        send("onboarding_page_viewed", ["page": String(page)])
    }

    enum Screen: String {
        case home, activity, settings, paywall, terminals, session, agentChat, agentReview, whatsNew
    }

    static func screen(_ screen: Screen) {
        context.withLock { $0.tab = screen }
        send("screen_viewed", ["screen": screen.rawValue])
    }

    /// A screen pushed or presented over a tab. The SDK names a rage click after the UIKit hosting controller, which says nothing about which SwiftUI screen it was.
    static func screenAppeared(_ screen: Screen) {
        context.withLock { $0.pushed = screen }
        send("screen_viewed", ["screen": screen.rawValue])
    }

    static func screenDisappeared(_ screen: Screen) {
        context.withLock { if $0.pushed == screen { $0.pushed = nil } }
    }

    /// Added to the SDK's own `$rageclick`: the screen the person was on, nothing they touched or typed.
    static func rageClickDetail() -> [String: Any] {
        let current = context.withLock { $0.pushed ?? $0.tab }
        return ["app_screen": current?.rawValue ?? "unknown"]
    }

    enum Panel: String {
        case shortcuts, clipboard, sources, settings, terminals, agents, files
    }

    static func panelOpened(_ panel: Panel) {
        send("panel_opened", ["panel": panel.rawValue])
    }

    enum Route: String {
        case discovered, relay, pairing, address
    }

    static func connectStarted(route: Route) {
        send("connect_started", ["route": route.rawValue])
    }

    /// `afterReady` tells a drop mid-session from a connection that never came up. `appState` and `pictureInPictureActive` tell a drop the network caused from one iOS caused by freezing the app.
    static func connectFailed(
        afterReady: Bool, reason: String, path: String, reconnectAttempt: Int,
        secondsIntoSession: Int?, appState: String, pictureInPictureActive: Bool
    ) {
        var properties = [
            "after_ready": String(afterReady), "reason": reason, "path": path,
            "reconnect_attempt": String(reconnectAttempt), "app_state": appState,
            "pip_active": String(pictureInPictureActive),
        ]
        if let secondsIntoSession { properties["seconds_into_session"] = String(secondsIntoSession) }
        send("connect_failed", properties)
    }

    static func name(of state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    static func paywallShown(reason: String) {
        send("paywall_shown", ["reason": reason])
    }

    static func paywallDismissed(reason: String) {
        send("paywall_dismissed", ["reason": reason])
    }

    /// `product` is one of `pro_monthly`, `pro_yearly`, `pro_lifetime` or `other`, never the store's own identifier.
    static func purchaseStarted(product: String) {
        send("purchase_started", ["product": product])
    }

    static func purchaseFinished(outcome: String, product: String) {
        send("purchase_finished", ["outcome": outcome, "product": product])
    }

    /// The day's remote time ran out, mid-session or at the next connect. The warning before it is the `running_low` paywall reason.
    static func relayAllowanceExhausted(path: String?) {
        send("relay_allowance_exhausted", ["path": path ?? "unknown"])
    }

    static func referralShared() {
        send("referral_shared", [:])
    }

    /// `outcome` is `redeemed` or a ``ReferralRefusal`` case name.
    static func referralRedeemed(outcome: String) {
        send("referral_redeemed", ["outcome": outcome])
    }

    enum Feature: String {
        case macro, agentChatStarted, agentChatResumed, agentChatStopped, agentChatContinuedInNew, agentPromptSent, fileUpload, sourceSelected, clipboardPush, sshConnected
        case pointerSpeedChanged, observeOnlyChanged, privacyModeChanged, macLocked, lockScreenShown
        case mosaicShown, mosaicTileResized, mosaicTileRemoved, applicationLaunched, keyboardModeChanged
        case autoQualityChanged, qualityChanged
        case clipboardPull, clipboardPushAndPaste, clipboardCopyHost, clipboardCopyToPhone, clipboardPushToMac, clipboardHistoryCleared
        case wakeOnLAN, terminalCreated, terminalRunCommand, terminalRenamed, terminalClosed
        case fileCreated, fileRenamed, fileDeleted, filePreviewed, fileSaved, folderUpload
        case sshHostSaved, sshHostDeleted, sshUnlocked, restorePurchases, macRenamed, macForgotten
        case remotePairingStarted, manualAddressConnect, intentRun, pipStarted
    }

    /// `agent` is one of the built-in agents' ids, or `other`: the list comes from the Mac, so an id is not sent as it arrives.
    static func featureUsed(_ feature: Feature, agent: String? = nil) {
        var properties = ["feature": feature.rawValue]
        let current = context.withLock { $0 }
        if let path = current.path { properties["path"] = path }
        if let plan = current.plan { properties["plan"] = plan }
        if let agent { properties["agent"] = ["claude", "codex", "opencode"].contains(agent) ? agent : "other" }
        send("feature_used", properties)
    }

    enum Area: String {
        case purchase, fileTransfer, ssh, audio, notification, liveActivity, security, preview
    }

    private static let reportFilter = OSAllocatedUnfairLock(initialState: ErrorReportFilter())

    /// Handled errors go to Error Tracking as the domain and code only: a message can carry a path, a Mac's name or an address.
    static func failed(_ error: Error, in area: Area, context: [String: String] = [:]) {
        guard isEnabled, PostHogConfiguration.isConfigured else { return }
        let nsError = error as NSError
        guard reportFilter.withLock({ $0.shouldReport(nsError, area: area.rawValue) }) else { return }
        let scrubbed = NSError(domain: nsError.domain, code: nsError.code)
        var properties: [String: Any] = ErrorDetail.properties(for: error).merging(context) { $1 }
        properties["area"] = area.rawValue
        properties["$process_person_profile"] = false
        PostHogSDK.shared.captureException(scrubbed, properties: properties)
    }

    static func settingChanged(_ name: String, to value: String) {
        send("setting_changed", ["setting": name, "value": value])
    }

    /// Watches the preferences a user can flip, so every switch in either settings screen is counted without a line in each view. Values are bools or members of closed enums.
    static func observeSettings() {
        SettingsObserver.shared.start()
    }

    private static func send(_ event: String, _ properties: [String: String]) {
        guard isEnabled, PostHogConfiguration.isConfigured else { return }
        var props: [String: Any] = properties
        props["$process_person_profile"] = false
        props["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        props["app_build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        props["os_major"] = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? ""
        PostHogSDK.shared.capture(event, properties: props)
    }
}

nonisolated private final class SettingsObserver: NSObject {
    nonisolated(unsafe) static let shared = SettingsObserver()
    private static let keys = [
        PreferenceKeys.hidesPanelAfterSelect, PreferenceKeys.pipAutoStart, PreferenceKeys.opensKeyboardForTextFields,
        PreferenceKeys.allowRelay, PreferenceKeys.requireBiometricUnlock, PreferenceKeys.hostAudioMuted,
        PreferenceKeys.liveActivities, PreferenceKeys.keyboardMode, PreferenceKeys.streamQuality,
        PreferenceKeys.interactionMode, PreferenceKeys.scalesToFill, PreferenceKeys.analyticsEnabled,
    ]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        for key in Self.keys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath, let new = change?[.newKey] else { return }
        let value: String
        switch new {
        case let bool as Bool: value = String(bool)
        case let text as String: value = text
        default: return
        }
        let name = keyPath.replacingOccurrences(of: "Peering.", with: "")
        Task { @MainActor in
            if name == "analyticsEnabled", value == "false" { return }
            Analytics.settingChanged(name, to: value)
        }
    }
}
