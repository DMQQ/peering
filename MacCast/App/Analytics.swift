import Foundation
import MacCastKit
import PostHog
import UIKit

/// Anonymous usage counts, on by default and off with one switch in Settings.
///
/// Never sent by these explicit events: a Mac's name or address, a file name, a command, anything typed or shown, or the id the relay meters by.
/// Every value is from a closed set (an enum or a bool), so nothing the user typed can reach an event by accident.
enum Analytics {
    private static let lastOpenKey = "Peering.analyticsLastOpen"
    /// A foreground within this of the last one is the same sitting, not a new open.
    private static let openGap: TimeInterval = 30 * 60

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.analyticsEnabled) as? Bool ?? true
    }

    static func appOpened(plan: RelayPlan?) {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastOpenKey)
        guard now - last > openGap else { return }
        UserDefaults.standard.set(now, forKey: lastOpenKey)
        send("app_opened", ["plan": plan?.rawValue ?? "unknown"])
    }

    static func sessionStarted(path: String, plan: RelayPlan?) {
        send("session_started", ["path": path, "plan": plan?.rawValue ?? "unknown"])
    }

    static func pairingDecided(accepted: Bool) {
        send(accepted ? "pairing_accepted" : "pairing_declined", [:])
    }

    static func sessionEnded(path: String) {
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
        case home, activity, settings, paywall, terminals, session
    }

    static func screen(_ screen: Screen) {
        send("screen_viewed", ["screen": screen.rawValue])
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

    /// `afterReady` tells a drop mid-session from a connection that never came up.
    static func connectFailed(afterReady: Bool, reason: String) {
        send("connect_failed", ["after_ready": String(afterReady), "reason": reason])
    }

    static func paywallShown(reason: String) {
        send("paywall_shown", ["reason": reason])
    }

    static func purchaseFinished(outcome: String) {
        send("purchase_finished", ["outcome": outcome])
    }

    enum Feature: String {
        case macro, agentChatStarted, agentPromptSent, fileUpload, sourceSelected, clipboardPush, sshConnected
        case pointerSpeedChanged, observeOnlyChanged, privacyModeChanged, macLocked, lockScreenShown
        case mosaicShown, mosaicTileResized, mosaicTileRemoved, applicationLaunched, keyboardModeChanged
        case autoQualityChanged, qualityChanged
        case clipboardPull, clipboardPushAndPaste, clipboardCopyHost, clipboardCopyToPhone, clipboardPushToMac, clipboardHistoryCleared
        case wakeOnLAN, terminalCreated, terminalRunCommand, terminalRenamed, terminalClosed
        case fileCreated, fileRenamed, fileDeleted, filePreviewed, fileSaved, folderUpload
        case sshHostSaved, sshHostDeleted, sshUnlocked, restorePurchases, macRenamed, macForgotten
        case remotePairingStarted, manualAddressConnect, intentRun, pipStarted
    }

    static func featureUsed(_ feature: Feature) {
        send("feature_used", ["feature": feature.rawValue])
    }

    enum Area: String {
        case purchase, fileTransfer, ssh, audio, notification, liveActivity, security, preview
    }

    /// Handled errors go to Error Tracking as the domain and code only: a message can carry a path, a Mac's name or an address.
    static func failed(_ error: Error, in area: Area) {
        guard isEnabled, PostHogConfiguration.isConfigured else { return }
        let nsError = error as NSError
        let scrubbed = NSError(domain: nsError.domain, code: nsError.code)
        PostHogSDK.shared.captureException(scrubbed, properties: ["area": area.rawValue, "$process_person_profile": false])
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
