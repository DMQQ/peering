import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

private let modelLog = Logger(subsystem: "pl.dmq.peering", category: "app")

/// Everything the UI binds to. One owner of the session, the identity and the renderer, so a
/// network event becomes observable state in exactly one place.
@Observable
@MainActor
final class SessionModel {
    let launchedAt = Date()

    /// Declared on ``MacSession`` and merely named here: the answer belongs to one connection (one Mac can be on this network while another is across the country).
    typealias ConnectionPath = MacSession.ConnectionPath

    typealias FileWrite = MacSession.FileWrite
    typealias FileChange = MacSession.FileChange

    typealias StreamQuality = MacCastKit.StreamQuality

    // MARK: - The sessions

    /// ``connect(to:)`` replaces the list with the session it starts, so it holds one at a time; per-Mac state lives on the objects.
    private(set) var sessions: [MacSession] = []

    /// The only place the container changes: a finished Mac is let go, except one still being retried.
    func place(_ session: MacSession, replacing old: MacSession?) {
        if let old { sessions.removeAll { $0 === old } }
        sessions.removeAll { !$0.isLive }
        sessions.append(session)
        activeSessionID = session.id
    }

    var activeSessionID: UUID?

    var activeSession: MacSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// A session that is open and one being watched are two things. While this is set, the control channel, shells, clipboard and sleep assertion stay and only the picture stops (see `setPicturePaused(_:)`).
    /// Put back by every route that shows a session: ``returnToSession()``, ``activateSession(_:)``,
    /// ``connect(to:replacing:)`` and ``disconnect(deliberate:)``.
    var isSessionOnScreen = true

    /// Held apart from `picturePaused` so coming back does not undo a pause somebody asked for. Internal so the end of a session can clear it.
    var pausedBySteppingAway = false

    /// Not `sessions`: an ended session is kept until the next arrives so its failure can be read, and it is not a tab.
    var openSessions: [MacSession] { sessions.filter(\.isLive) }

    var hasOpenSession: Bool { !openSessions.isEmpty }

    /// The first Mac is free on every plan, so the question is "is this paid, or the first one".
    var canAddAnotherSession: Bool {
        storeManager.access.includes(.concurrentSessions) || openSessions.isEmpty
    }

    /// A ceiling on the phone: each open Mac costs a control connection, a keepalive and a sleep assertion.
    static let sessionCeiling = 4

    // MARK: - Connection state

    var phase: ClientSession.Phase {
        get { activeSession?.phase ?? .idle }
        set { activeSession?.phase = newValue }
    }
    var hosts: [DiscoveredHost] = []

    /// Re-derived from Bonjour at the dial, which is the one moment it cannot be trusted: after a backgrounding its mDNS results are stale and a re-browse takes seconds. Kept on disk so a relaunch dials at once; an address from a network since left loses the race to the relay. See ``DialRace``.
    private var lastLANHosts: [String: DiscoveredHost] = RememberedLANHosts.load() {
        didSet { RememberedLANHosts.save(lastLANHosts) }
    }

    func rememberLANHost(_ host: DiscoveredHost) {
        lastLANHosts[host.id] = host
    }

    func rememberedLANHost(_ hostID: String) -> DiscoveredHost? {
        lastLANHosts[hostID]
    }

    static let standardConnectTimeout: TimeInterval = 10

    /// Short, because it is the one dial whose address may be wrong.
    static let rememberedPathTimeout: TimeInterval = 3

    /// Three states, so not a `Set`: an absent key is nobody having found out.
    var relayPresence: [String: Bool] = [:]
    var relayReachable: Bool? = nil

    /// Not a `Bool`: "not reachable" is two facts and only one is about the Mac.
    enum Reachability: Equatable {
        case nearby
        case viaRelay
        /// Not quite "switched off": a Mac can be awake on its own network while registered nowhere.
        case notRegistered
        case unknown

        var isReachable: Bool {
            switch self {
            case .nearby, .viaRelay: return true
            case .notRegistered, .unknown: return false
            }
        }
    }

    func reachability(ofHost hostID: String) -> Reachability {
        if hosts.contains(where: { $0.id == hostID }) { return .nearby }
        switch relayPresence[hostID] {
        case true?: return .viaRelay
        case false?: return .notRegistered
        case nil: return .unknown
        }
    }
    var browseStatus = String(localized: "Looking for Macs on this network…")
    var tlsDescription: String?

    var sessionHistory: [ClientSessionRecord] = SessionHistoryStore.load()
    var pairedHostIDs: [String] = []

    /// The bitrate preset; redrawing on change requires a stored var, not a UserDefaults read.
    var streamQuality: StreamQuality = SessionModel.storedQuality
    /// Seeded from the stored preference so Automatic to Manual returns to the last saved level; nil when the stored value is automatic.
    var lastManualQuality: StreamQuality? = .storedManualLevel()

    // MARK: - Clipboard
    var hostClipboard: ClipboardPayload? {
        get { activeSession?.hostClipboard }
        set { activeSession?.hostClipboard = newValue }
    }

    var clipboardPulling: Bool {
        get { activeSession?.clipboardPulling ?? false }
        set { activeSession?.clipboardPulling = newValue }
    }

    // MARK: - Wake-on-LAN
    var hostMACAddresses: [String: [String]] = {
        guard let data = UserDefaults.standard.data(forKey: "hostMACAddresses"),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    // MARK: - Audio

    /// One Mac's sound at a time.
    var audioPlayer: RemoteAudioPlayer? {
        get { activeSession?.audioPlayer }
        set { activeSession?.audioPlayer = newValue }
    }

    /// The channel also carries system sounds the Mac makes in response to this phone's input, so a chord that leads nowhere is heard a round trip late.
    var hostAudioMuted = UserDefaults.standard.object(forKey: PreferenceKeys.hostAudioMuted) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hostAudioMuted, forKey: PreferenceKeys.hostAudioMuted)
            // Every Mac, not the one on screen: one behind it would keep playing unnoticed.
            for session in sessions { session.refreshAudioMuteState() }
        }
    }

    /// The audio arrives over a connection the user already has, so a free user would still hear it unless the player is told.
    var playsHostAudio: Bool {
        !hostAudioMuted && storeManager.access.includes(.macSound)
    }

    // MARK: - Terminals

    var terminals: [RemoteTerminal] {
        get { activeSession?.terminals ?? [] }
        set { activeSession?.terminals = newValue }
    }

    var selectedTerminalID: UUID? {
        get { activeSession?.selectedTerminalID }
        set { activeSession?.selectedTerminalID = newValue }
    }

    // MARK: - File browsing

    var directories: [RemoteDirectoryKey: RemoteDirectory] {
        get { activeSession?.directories ?? [:] }
        set { activeSession?.directories = newValue }
    }

    var browsingPaths: [UUID: String] {
        get { activeSession?.browsingPaths ?? [:] }
        set { activeSession?.browsingPaths = newValue }
    }

    var pendingDirectories: Set<RemoteDirectoryKey> {
        get { activeSession?.pendingDirectories ?? [] }
        set { activeSession?.pendingDirectories = newValue }
    }

    var browseFailures: [RemoteDirectoryKey: String] {
        get { activeSession?.browseFailures ?? [:] }
        set { activeSession?.browseFailures = newValue }
    }

    var filePreview: RemoteFilePreview? {
        get { activeSession?.filePreview }
        set { activeSession?.filePreview = newValue }
    }

    var pendingRun: String? {
        get { activeSession?.pendingRun }
        set { activeSession?.pendingRun = newValue }
    }

    var writes: [UUID: FileWrite] {
        get { activeSession?.writes ?? [:] }
        set { activeSession?.writes = newValue }
    }

    var saveFailures: [UUID: String] {
        get { activeSession?.saveFailures ?? [:] }
        set { activeSession?.saveFailures = newValue }
    }
    var uploadFailures: [UUID: String] {
        get { activeSession?.uploadFailures ?? [:] }
        set { activeSession?.uploadFailures = newValue }
    }

    var changes: [UUID: FileChange] {
        get { activeSession?.changes ?? [:] }
        set { activeSession?.changes = newValue }
    }

    var changeFailures: [UUID: String] {
        get { activeSession?.changeFailures ?? [:] }
        set { activeSession?.changeFailures = newValue }
    }

    /// The pin store knows only the ID, and the handshake is the only moment the client is told both.
    var hostNames: [String: String] = [:]

    /// The relay answers for whatever holds the ID, so "not registered" and a mistyped digit look the same; only the ID asked for tells them apart. Cleared by every other connect.
    var remotePairingHostID: String?

    var lastConnectedAt: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "hostLastConnectedAt"),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    /// The phase carries it, and the picker needs it: otherwise an instantly failed connection looks like a button that did nothing.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Kept apart from `hostNames`, which is rewritten from `ServerHello` on every connect, so a rename stored there would silently revert.
    var customHostNames: [String: String] = [:]

    /// Set when the device's own identity could not be loaded: without a client certificate there is
    var identityFailure: String?

    // MARK: - User choices

    /// Remembered but deliberately not used to reconnect: a stored IP goes stale exactly when a network changes. Kept so a Mac on a custom port is not retyped each launch.
    var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: Self.manualAddressKey) }
    }
    var manualPort: String {
        didSet { UserDefaults.standard.set(manualPort, forKey: Self.manualPortKey) }
    }

    static let manualAddressKey = "Peering.manualAddress"

    static var defaultDeviceName: String {
        // UIDevice.current.name needs Apple approval for the custom name entitlement on iOS 16+, so
        // fall back to a recognisable-enough label until the user sets one in Settings.
        let name = UIDevice.current.name
        if name.lowercased() == "iphone" || name.lowercased() == "ipad" {
            return UIDevice.current.localizedModel + " (" + UIDevice.current.systemVersion + ")"
        }
        return name
    }
    static let manualPortKey = "Peering.manualPort"
    var keyboardMode: KeyboardMode = KeyboardMode(
        rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.keyboardMode) ?? "unicode"
    ) ?? .unicode
    var isObserving = false
    var latchedModifiers: Modifiers = []

    /// A number rather than an index so label and arithmetic agree; persisted as a property of the hand.
    var pointerSpeed: Double =
        UserDefaults.standard.object(forKey: PreferenceKeys.pointerSpeed) as? Double ?? 1

    var showKeyboard = false {
        didSet {
            // Putting the keyboard away ends the line this bar was keeping: nothing would ever correct it, and this is the way out of a drifted preview.
            if !showKeyboard { typedPreview = "" }
            keyboardOpenedByFocus = false
        }
    }

    /// Whether the keyboard is up because a Mac text field took focus, so it may close itself
    /// again when focus leaves. A keyboard the user opened is theirs to close.
    var keyboardOpenedByFocus = false

    /// A keyboard the Mac asked for must not close a panel the user opened: switching desktops from the sources panel moves focus into the new desktop's text field.
    var isPanelOpen = false

    func textFocusChanged(_ focus: TextFocus) {
        let enabled = UserDefaults.standard.object(forKey: PreferenceKeys.opensKeyboardForTextFields) as? Bool ?? true
        typedDraft = ""
        pendingField = nil
        fieldCaret = nil
        guard enabled, !isObserving, !isShowingMosaic, !isPanelOpen else { return }
        if focus.isEditable {
            guard !showKeyboard else { return }
            showKeyboard = true
            keyboardOpenedByFocus = true
        } else if keyboardOpenedByFocus {
            showKeyboard = false
        }
    }

    /// The bar's own record, emptied by Return, a newline as text, and the keyboard going away. Anything that sends characters must go through `handleTypedText(_:)` and `handleBackspace()`, or this shows a character the Mac has lost.
    var typedPreview = ""

    /// Kept here because the field is rebuilt each time the keyboard opens; the Mac's field keeps its text, so the phone's must. It ends with a Return or when the Mac's focus moves.
    var typedDraft = ""

    /// Bumped when the Mac's field is applied, so the field takes `typedDraft` and `draftSelection` as they now stand.
    var fieldSerial = 0
    var draftSelection = NSRange(location: 0, length: 0)
    var fieldCaret: NormalizedPoint?
    /// When the phone's field last changed by typing: the Mac's report of a line still being typed is older than the line, and applying it would delete the last characters.
    var lastLocalEdit = Date.distantPast
    private var pendingField: FieldState?

    func fieldStateChanged(_ state: FieldState) {
        fieldCaret = state.caret
        guard state.text != nil else { return }
        pendingField = state
        applyPendingFieldWhenQuiet()
    }

    private func applyPendingFieldWhenQuiet() {
        guard let state = pendingField, let text = state.text else { return }
        let wait = Self.fieldSettleTime - Date().timeIntervalSince(lastLocalEdit)
        if wait > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.applyPendingFieldWhenQuiet()
            }
            return
        }
        pendingField = nil
        typedDraft = text
        draftSelection = NSRange(location: state.selectionLocation, length: state.selectionLength)
        fieldSerial += 1
    }

    private static let fieldSettleTime: TimeInterval = 0.8

    // MARK: - Purchase

    let storeManager = StoreManager()
    var paywallReason: PaywallView.Reason?

    /// The one case where a session ends and nothing says why: the relay stops splicing silently, so this end sees an ordinary close and reconnects, and the reason first exists when the reconnect is refused with `quotaExceeded`.
    var spentAllowance: RelayPlan?

    /// `quotaExceeded` looks identical whether the user tapped Connect into a spent allowance or the relay cut a running session, and only the first is a wall they walked into.
    var relaySessionDropped = false

    /// Closing alone is not enough: a failed attempt during a resume is swallowed, so the phase can be left on a connecting state with nothing behind it.
    func dismissSpentAllowance() {
        spentAllowance = nil
        if phase.holdsSession, phase != .ready {
            disconnect()
        }
    }

    // MARK: - Collaborators

    let renderer = VideoRenderer()

    let pins = ClientPinStore.standard
    let browser = HostBrowser()

    var networkWatcher: NetworkPathWatcher?
    let notifier = SessionNotifier.shared

    /// The browser replaces a dead one itself, but a suspended app is not running to do it, so the foreground is the moment to restart.
    var browseFailed = false
    var identity: SelfSignedIdentity?
    var device = DeviceIdentity(id: "", name: "")

    /// A task rather than a timestamp: the showing must be cancellable, not the decision, and it doubles as the flag that stops a second offer.
    var pendingOffer: Task<Void, Never>?

    init() {
        device = DeviceIdentity.loadOrCreate(defaultName: Self.defaultDeviceName)
        pairedHostIDs = pins.hostIDs
        hostNames = UserDefaults.standard.dictionary(forKey: Self.hostNamesKey) as? [String: String] ?? [:]
        customHostNames = UserDefaults.standard.dictionary(forKey: Self.customHostNamesKey) as? [String: String] ?? [:]
        let defaults = UserDefaults.standard
        manualAddress = defaults.string(forKey: Self.manualAddressKey) ?? "127.0.0.1"
        manualPort = defaults.string(forKey: Self.manualPortKey) ?? String(ProtocolInfo.defaultPort)
        do {
            identity = try SelfSignedIdentity.loadOrCreate(role: .client, commonName: device.name)
        } catch {
            identityFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            modelLog.error("could not load the client identity: \(String(describing: error), privacy: .public)")
        }

        renderer.onFirstFrame = { [weak self] in
            self?.frameArrived += 1
        }
    }

    /// A hero transition's cue to drop its frozen snapshot: the renderer runs off the main actor and is not observable, so a plain read cannot say the picture is decoded.
    var frameArrived = 0

    /// The size identifies the stream, as the order a frame and its config reach the main actor cannot be relied on.
    func isReadyToPlace(of size: CGSize) -> Bool {
        let snapshot = renderer.currentSnapshot
        return snapshot.configGeneration > 0
            && snapshot.readyGeneration == snapshot.configGeneration
            && snapshot.pixelWidth == Int(size.width)
            && snapshot.pixelHeight == Int(size.height)
    }

    // MARK: - Push token

    /// Held here because reading it is an `await` on the system.
    private(set) var notificationsAuthorized = false

    /// Read through the notifier rather than copied, as it is written from an app-delegate callback.
    var pushRegistration: String? {
        if notifier.remoteToken != nil { return String(localized: "Yes") }
        return notifier.remoteTokenFailure
    }

    func refreshNotificationAuthorization() async {
        notificationsAuthorized = await notifier.refreshAuthorization()
    }

    /// This is the gate for the push half, here rather than at the Mac, which sends to a token and knows nothing else: a phone that never hands one over cannot be reached on any plan.
    /// An empty registration is sent rather than skipped: it forgets the token the Mac was given while the plan included it, which a lapsed subscription needs.
    /// Nothing is sent while the entitlement has not been read, so a subscriber is not stripped at launch.
    func sendPushToken() {
        guard let plan = storeManager.access.plan else { return }

        guard plan.includes(.terminalAlerts) else {
            for session in sessions where session.phase == .ready {
                session.wire?.sendTerminal(.registerPushToken(Data()))
            }
            return
        }

        guard let token = SessionNotifier.shared.remoteToken else { return }
        for session in sessions where session.phase == .ready {
            session.wire?.sendTerminal(.registerPushToken(token))
        }
    }

    // MARK: - Clipboard history

    /// The Mac's pasteboard holds one thing, so this is the only place earlier pulls exist; held here because the panel is rebuilt each time it opens.
    var clipboardHistory: [ClipboardEntry] = SessionModel.loadClipboardHistory()

    /// A count so a view can tell the list changed: entries carry no identity and text can repeat.
    var clipboardHistoryCount = 0

    /// Reading the pasteboard asks the user, so this is the only text the panel can show for free, and only while the change count matches.
    var knownPhoneClipboard: (changeCount: Int, text: String)?

    // MARK: - Wake-on-LAN

    /// A magic packet is an unacknowledged UDP broadcast, so silence would look like a row that did nothing; the sentence carries the limit that it does not leave the network.
    func wakeHost(id: String) {
        Analytics.featureUsed(.wakeOnLAN)
        let addresses = hostMACAddresses[id] ?? []
        let sent = addresses.filter { WakeOnLAN.send(to: $0) }.count
        guard sent > 0 else {
            append(note: addresses.isEmpty
                ? String(localized: "No hardware address is on file for that Mac, so there is nothing to send a wake packet to.")
                : String(localized: "That Mac's stored hardware address could not be read, so no wake packet was sent."))
            return
        }
        append(note: sent == 1
            ? String(localized: "Wake packet sent to 1 hardware address. It can only reach a Mac on this network.")
            : String(localized: "Wake packet sent to \(sent) hardware addresses. It can only reach a Mac on this network."))
    }

    var pendingHostID: String?

    var isWaitingForHost: Bool { pendingHostID != nil }

    /// The one thing that can turn a feature off outright: it promises the Mac's device ID and connection times never reach a server, keepable only if this gates every dial (`connectToTrusted`, `reconnectToLastHost`, `resumeIfNeeded`, `pairWithRemoteMac`).
    /// Read through `object(forKey:)` so unset is distinguishable from off: the default is on.
    var allowsRelay: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.allowRelay) as? Bool ?? true
    }

    static let lastHostNameKey = "Peering.lastHostName"
    static let lastHostIDKey = "Peering.lastHostID"

    static let resumeKey = "Peering.resumeWhenReachable"

    /// Read off the session on screen, because the card describes one Mac.
    var isReconnecting: Bool {
        get { activeSession?.isReconnecting ?? false }
        set { activeSession?.isReconnecting = newValue }
    }

    /// The rule is ``SessionResume``'s; screens ask here to read one answer.
    var isResumingAfterDrop: Bool { activeSession?.isResumingAfterDrop ?? false }

    var isBeingPutBack: Bool { activeSession?.isBeingPutBack ?? false }

    /// Spread out: the usual cause is a sleeping Mac or a brief network loss, and retrying every second spends radio and battery on an unchanged answer. Five attempts over about forty seconds cover a Wi-Fi roam and a Mac waking.
    static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(20),
    ]

    /// A resume is silent, so "still coming back" and "gone" look alike and the only difference the user can act on is how long they wonder: hence short, with a nearly immediate first rung.
    /// The two ladders share a counter: `reconnectAttempt` indexes into whichever is in use and is carried across a dial, so the shorter simply runs out sooner.
    static let resumeReconnectDelays: [Duration] = [
        .milliseconds(250), .seconds(1), .seconds(3),
    ]

    /// A rung is a wait plus a dial that can take ten seconds to fail, so "three rungs" is not a duration, and a dial that never answers is not bounded by the count. This bound does not depend on the network answering and covers the restoration, which dials once with no ladder.
    static let reconnectWindow: TimeInterval = 10

    var reconnectTask: Task<Void, Never>? {
        get { activeSession?.reconnectTask }
        set { activeSession?.reconnectTask = newValue }
    }

    var reconnectAttempt: Int {
        get { activeSession?.reconnectAttempt ?? 0 }
        set { activeSession?.reconnectAttempt = newValue }
    }

    /// Coming back to the foreground races the teardown of the session that just ended: its cancelled socket is not finished with, so the connect aborts before it starts. It clears within a second and nobody asked for this attempt, so nobody is told.
    var isResuming = false

    /// One flag for every Mac, so the last to finish clears it, asked of the sessions.
    func clearResumingIfNothingIsUnderWay() {
        guard !sessions.contains(where: { $0.isResumingAfterDrop }) else { return }
        isResuming = false
    }

    var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var thisDeviceDescription: String { "\(device.name) · \(device.id)" }

    // MARK: - Input

    var customMacros: [Macro] = {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKeys.customMacros),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else {
            return []
        }
        return decoded
    }()

    var allMacros: [Macro] { Macro.defaults + customMacros }

    // MARK: - Commands to the active Mac

    // Forwarders: a command belongs to a session. A terminal ID came from the Mac that made it and is unique across Macs, which routes it to its owner rather than the one on screen.

    /// App-wide rather than per Mac: this is the shortlist the panel offers, and a command from one Mac is likely wanted on another.
    /// Stored, not computed from the defaults: nothing observes `UserDefaults`.
    var terminalHistory: [String] =
        UserDefaults.standard.stringArray(forKey: PreferenceKeys.terminalHistory) ?? []
}
