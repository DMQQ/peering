import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

private let modelLog = Logger(subsystem: "pl.dmq.peering", category: "app")

/// Which keyboard the user is driving the Mac with.
/// Not a preference: the two are different protocols. `unicode` sends `textInput` (emoji and CJK arrive intact, but no keycode is pressed so ⌘S never fires); `keycode` presses real virtual keycodes, so shortcuts work but a character with no keycode on the Mac's layout cannot be typed.
enum KeyboardMode: String, CaseIterable, Identifiable {
    case unicode
    case keycode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unicode: return String(localized: "Unicode")
        case .keycode: return String(localized: "Keycode")
        }
    }

    var explanation: String {
        switch self {
        case .unicode:
            return String(localized: "Sends text. Emoji and non-Latin scripts work; Mac shortcuts like ⌘S do not.")
        case .keycode:
            return String(localized: "Sends real key presses with modifiers. Shortcuts work; characters outside the Mac's layout cannot be typed.")
        }
    }
}

struct Macro: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let keyCode: UInt16
    let modifiers: Modifiers

    static let defaults: [Macro] = [
        // macOS virtual keycodes, the values `CGEvent` takes, not USB HID usages or characters.
        Macro(id: "copy",      title: "⌘C",     keyCode: 8,  modifiers: .command),
        Macro(id: "paste",     title: "⌘V",     keyCode: 9,  modifiers: .command),
        Macro(id: "cut",       title: "⌘X",     keyCode: 7,  modifiers: .command),
        Macro(id: "undo",      title: "⌘Z",     keyCode: 6,  modifiers: .command),
        Macro(id: "save",      title: "⌘S",     keyCode: 1,  modifiers: .command),
        Macro(id: "close",     title: "⌘W",     keyCode: 13, modifiers: .command),
        Macro(id: "appswitch", title: "⌘⇥",     keyCode: 48, modifiers: .command),
        Macro(id: "spotlight", title: "⌘Space", keyCode: 49, modifiers: .command),
        Macro(id: "escape",    title: "esc",    keyCode: 53, modifiers: []),
        Macro(id: "return",    title: "⏎",      keyCode: 36, modifiers: []),
        Macro(id: "ctrl-c",    title: "⌃C",     keyCode: 8,  modifiers: .control),
        Macro(id: "ctrl-z",    title: "⌃Z",     keyCode: 6,  modifiers: .control),
        Macro(id: "ctrl-d",    title: "⌃D",     keyCode: 2,  modifiers: .control),
        Macro(id: "ctrl-l",    title: "⌃L",     keyCode: 37, modifiers: .control),
        Macro(id: "ctrl-a",    title: "⌃A",     keyCode: 0,  modifiers: .control),
        Macro(id: "ctrl-e",    title: "⌃E",     keyCode: 14, modifiers: .control),
        Macro(id: "ctrl-r",    title: "⌃R",     keyCode: 15, modifiers: .control),
    ]
}

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

    /// The cheap one: only which Mac's picture is decoded changes; the Mac left is asked to pause.
    /// A no-op for the session already on screen, deliberately: asking for its picture again would blink it.
    func activateSession(_ id: UUID) {
        guard id != activeSessionID else {
            returnToSession()
            return
        }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Stopped before the switch: otherwise both Macs stream for the handover.
        activeSession?.setPicturePaused(true)
        let left = activeSession
        activeSessionID = id
        session.setPicturePaused(false)
        // Arriving at a Mac is being on its screen, and a pause taken for stepping away went with the old screen.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // The sound follows the tab: a player for the Mac on screen keeps playing after the user looks away unless told.
        left?.refreshAudioMuteState()
        session.refreshAudioMuteState()

        // Its own entry point rather than a phase change: the Mac arrived at has its own clock.
        SessionActivity.shared.followActiveSession(
            hostName: session.hostName ?? String(localized: "the Mac"),
            startedAt: session.sessionStartedAt,
            phase: session.phase,
            reconnecting: session.isReconnecting,
            path: MacSession.activityPath(session.connectionPath),
            sessionCount: openSessions.count
        )
        publishOpenMacs()
        session.publishWork()
    }

    /// Nothing is sent that could not be sent back, unlike `disconnect(deliberate:)`.
    /// The pause is taken only if the user had not already asked for one and nothing else watches: a picture floating in PiP keeps arriving. A Mac too old to be asked for silence streams at nobody, the honest failure.
    func stepAwayFromSession() {
        guard isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = false
        if !session.picturePaused, !session.isWatched {
            pausedBySteppingAway = true
            session.setPicturePaused(true)
        }
        session.refreshAudioMuteState()
    }

    func returnToSession() {
        guard !isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = true
        if pausedBySteppingAway {
            pausedBySteppingAway = false
            session.setPicturePaused(false)
        }
        session.refreshAudioMuteState()
    }

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

    private var networkWatcher: NetworkPathWatcher?
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

    // MARK: - Discovery

    func start() {
        guard identityFailure == nil else { return }
        // Anything on the Lock Screen from a previous run describes a session this process did not survive.
        SessionActivity.shared.adoptOrphan()
        browser.onEvent = { [weak self] event in
            // Bound once outside the `Task`: a `weak self` is a mutable variable and reading it from an outliving closure is a data race.
            guard let self else { return }
            // HostBrowser reports from its own queue, and each of these touches observable state.
            Task { @MainActor in self.apply(event) }
        }

        // Started with the app, not at the first drop: the watcher compares against the path of the last dial, so one begun at a drop would call its first update a change.
        let watcher = NetworkPathWatcher()
        watcher.hasSomethingToPutBack = { [weak self] in
            self?.sessions.contains { $0.isResumingAfterDrop } ?? false
        }
        watcher.onUsableChange = { [weak self] in self?.networkChanged() }
        watcher.onPathChange = { [weak self] in self?.verifyLiveSessions() }
        networkWatcher = watcher
        watcher.start()
    }

    /// For the moment a wait begins, not when the network moves (the relay case). Deferred by a turn at the call site, because it can dial.
    func considerNetworkChange() {
        networkWatcher?.judgeNow()
    }

    /// Only for a Mac on its way back.
    /// The counter is deliberately not reset, which keeps the ladder finite on a phone whose network flaps; dialling early costs a rung, not the ladder.
    private func networkChanged() {
        for session in sessions where session.isResumingAfterDrop {
            session.stopReconnecting()
            session.resumeIfNeeded()
        }
    }

    /// Asks every connected Mac to answer now, so a connection that died with the old network or suspension is redialled at once rather than after the silence watchdog.
    func verifyLiveSessions() {
        for session in sessions where session.phase == .ready {
            session.wire?.verifyStillAnswering()
            if !session.isVideoStreaming {
                session.wire?.retryVideoAfterNetworkChange()
            }
        }
    }

    func startBrowsing() {
        browser.start()
    }

    func restartBrowsing() {
        browseStatus = String(localized: "Looking for Macs on this network…")
        browser.stop()
        browser.start()
    }

    /// Any Mac, not the one on screen: gating on the active session's phase would enable the row the moment the user looked at a Mac that had finished.
    var isBusy: Bool { hasOpenSession }

    func connect(to target: ClientSession.Target) {
        connect(to: target, replacing: nil)
    }

    /// Written out rather than asked of `ClientSession/Target`, whose answer is internal to `RemoteCore`.
    private static func hostID(of target: ClientSession.Target) -> String? {
        switch target {
        case .discovered(let host): return host.id
        case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
        case .address: return nil
        }
    }

    /// - Parameter old: the session this attempt supersedes, removed rather than pruned since two entries for one Mac read as "it connected twice".
    func connect(
        to target: ClientSession.Target,
        replacing old: MacSession?,
        timeout: TimeInterval = SessionModel.standardConnectTimeout,
        racingRelay relay: ClientSession.Target? = nil
    ) {
        CrashLog.note("dial \(Self.hostID(of: target) ?? "unknown")\(old == nil ? "" : ", replacing a session") · \(sessions.count) open")
        guard let identity, identityFailure == nil else { return }

        // A Mac already open is brought to the front, not dialled again: two sessions would be two clients on the Mac. Every route passes here.
        // Not for a ladder putting a Mac back: `old` is how it says so.
        if old == nil, let hostID = Self.hostID(of: target),
           let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }

        // The screen goes to the Mac from the first frame of the connecting card, so a stepped-away session dialled again does not leave the picker up behind it.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // The gate, at the one place every route passes: a gate on one door can be walked past by another.
        // A ladder putting a Mac back is not gated: the plan was checked when it opened, and asking again would end a paid session mid-reconnect.
        if old == nil, hasOpenSession, !canAddAnotherSession {
            paywallReason = .feature(.concurrentSessions)
            return
        }
        // Said rather than silently refused: the ceiling is a fact about this phone, and a tap that did nothing would read as broken.
        if old == nil, openSessions.count >= Self.sessionCeiling {
            append(note: String(localized: "This device holds \(Self.sessionCeiling) Macs open at once. Close one to open another."))
            return
        }

        // Remembered for the widget, which can offer to connect but cannot know to what. Written twice: the app reads its own defaults, the widget only the shared container.
        UserDefaults.standard.set(target.displayName, forKey: Self.lastHostNameKey)
        SharedStore.lastHostName = target.displayName
        // A widget is not told anything, so without this it keeps showing the previous Mac until the system refreshes it.
        WidgetCenter.shared.reloadAllTimelines()

        // An attempt from the backoff timer would race this one and start a second session.
        stopReconnecting()
        // A session already up is torn down rather than replaced: assigning over it leaves the first connection running unheld, so the peer sees it drop mid-handshake, which with a retry is a loop.
        activeSession?.connectTask?.cancel()
        activeSession?.connectTask = nil
        activeSession?.wire?.disconnect()
        // The user has just asked to reach a Mac, the first moment "tell you when it needs you?" means anything.
        notifier.prepareForFirstConnect()

        let session = MacSession(model: self, renderer: renderer)

        // Cleared for every new session: a punched path belongs to the session that proved it, and a stale `true` would report a direct path not in use.
        session.usedDirectPath = false
        switch target {
        case .discovered(let host):
            session.connectionPath = .lan
            remotePairingHostID = nil
            UserDefaults.standard.set(host.id, forKey: Self.lastHostIDKey)
            lastLANHosts[host.id] = host
        case .relay(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = nil
            UserDefaults.standard.set(hostID, forKey: Self.lastHostIDKey)
        case .relayPairing(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = hostID
            // Nothing is proven to be this Mac yet, so nothing is remembered as the last Mac: a half-typed ID would be dialled again by the ladder.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        case .address:
            session.connectionPath = .direct
            remotePairingHostID = nil
            // The handshake replaces this with the real ID; a different Mac's ID in the window could make a retry dial the relay for the wrong machine.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        }
        if old == nil {
            switch target {
            case .discovered: Analytics.connectStarted(route: .discovered)
            case .relay: Analytics.connectStarted(route: .relay)
            case .relayPairing: Analytics.connectStarted(route: .pairing)
            case .address: Analytics.connectStarted(route: .address)
            }
        }
        // Fresh for the path this session just chose: the policy's tier is tuned per path.
        session.autoQualityPolicy = AutoQualityPolicy(path: session.autoQualityPath)
        session.lastAutoDroppedFrames = 0

        // Two facts belong to the Mac, not this attempt, and are carried across a dial of that Mac only.
        // `hasBeenReady` tells a resume from a first connection: the ladder builds a new object, so otherwise a blip would put the connecting card back.
        // `reconnectAttempt` is carried because the object is replaced on every attempt, or a failing Mac would stay on the first rung.
        // The third fact cannot be carried from `old`: a cold launch's restoration has no session behind it, so the intent arrives on the model. See `isComingBack`.
        session.isComingBack = isResuming

        if let old, let targetID = target.hostID, targetID == old.hostID {
            session.hasBeenReady = old.hasBeenReady
            session.reconnectAttempt = old.reconnectAttempt
            // And the clock the window is measured on: the run of attempts is one run however many objects it spans.
            session.reconnectingSince = old.reconnectingSince

            // And which source was on screen: the Mac keeps capturing the same display across a client reconnect, so forgetting it would make `PictureIdentity` read a different picture and `RemoteScreen` reset zoom and pan.
            // The catalogue is deliberately not carried: the Mac resends it on `.ready`, and a stale one naming gone sources is worse than none.
            session.activeSourceID = old.activeSourceID

            // The arrangement choices, not `isAskingForMosaic` or `askedMosaicLayout`: those are side effects of asking, and the reconnect's catalogue-triggered re-ask (`pendingSourceReassertion`) writes them from these. Uncarried, `activeSourceID` named the arrangement while nothing else agreed: no borders, no tile taps, no way back.
            session.mosaicChoices = old.mosaicChoices

            // The renderer and screen survive a reconnect, so the description of the picture they show must too, or the grid looks intact but has no overlay or hit targets until a matching config arrives. The next source-tagged config replaces it.
            session.pictureMosaicLayout = old.pictureMosaicLayout
        }

        // The episode begins with the dial, not only a rung: a restoration and the relay-to-LAN handover dial with no ladder, so a dial that never answers is otherwise unbounded. See `reconnectWindow`.
        if isResuming, session.reconnectingSince == nil {
            session.reconnectingSince = Date()
        }

        session.hostName = target.displayName

        let race = relay == nil ? nil : DialRace(session: session)
        session.dialRace = race
        let (wire, gate) = makeWire(for: session, identity: identity, race: race)
        let resumeSource = old?.hostID == target.hostID ? old?.sourceToResume : nil
        wire.resumeSource = resumeSource
        session.wire = wire
        // The only place the container changes: a finished Mac is let go, except one still being retried.
        if let old { sessions.removeAll { $0 === old } }
        sessions.removeAll { !$0.isLive }
        sessions.append(session)
        activeSessionID = session.id
        publishOpenMacs()

        // Whether a missing picture could be a network blocking video depends on where the Mac is: Bonjour means this network, while the relay and a typed address cross networks nobody here controls.
        // On the relay the picture shares the control channel, so asking there reduces rate rather than moving.
        wire.videoFallbackEnabled = session.connectionPath != .lan
        session.startVideoPolling()

        let connectTask = Task { [weak session, weak wire] in
            guard let wire else { return }
            await wire.connect(to: target, timeout: timeout)
            await MainActor.run {
                guard session?.wire === wire else { return }
                session?.connectTask = nil
            }
        }
        session.connectTask = connectTask

        if let race, let relay {
            race.add(wire, gate: gate, path: session.connectionPath ?? .lan)
            race.startLater(after: Self.relayHeadStart) { [weak self, weak session] in
                guard let self, let session, session.dialRace === race else { return }
                let (rival, rivalGate) = self.makeWire(for: session, identity: identity, race: race)
                race.add(rival, gate: rivalGate, path: .relay)
                rival.resumeSource = resumeSource
                rival.videoFallbackEnabled = true
                Task { await rival.connect(to: relay, timeout: Self.standardConnectTimeout) }
            }
        }
    }

    /// The LAN is free so it gets the first chance, but a Mac on the same network answers well within this.
    static let relayHeadStart: Duration = .milliseconds(300)

    private func makeWire(
        for session: MacSession,
        identity: SelfSignedIdentity,
        race: DialRace?
    ) -> (ClientSession, WireGate) {
        // Bound outside the closure (network queue). Frames and configs go straight to the renderer's queue in wire order: hopping the main actor would put a 60 Hz stream behind layout.
        let renderer = self.renderer
        let gate = WireGate(admitted: race == nil)
        let box = WeakWire()
        let wire = ClientSession(
            identity: identity,
            clientID: device.id,
            clientName: device.name,
            pins: pins,
            onEvent: { [weak session, weak race] event in
                let admitted: Bool
                if case .video(let video) = event {
                    switch video {
                    case .frame(let frame):
                        if gate.pass(video: video) { renderer.enqueue(frame) }
                        return
                    case .config(let config):
                        admitted = gate.pass(video: video)
                        if admitted { renderer.configure(config) }
                    default:
                        admitted = gate.isAdmitted
                    }
                } else {
                    admitted = gate.isAdmitted
                }
                if admitted {
                    Task { @MainActor in session?.apply(event) }
                } else {
                    let wire = box.wire
                    Task { @MainActor in if let wire { race?.receive(event, from: wire) } }
                }
            }
        )
        box.wire = wire
        return (wire, gate)
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

    static let terminalHistoryLimit = 30

    /// De-duplicated so a repeated command moves to the top, and capped: this is a convenience, the Mac's own shell keeps the history.
    func rememberTerminalCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = terminalHistory
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > Self.terminalHistoryLimit {
            history.removeLast(history.count - Self.terminalHistoryLimit)
        }
        terminalHistory = history
        forgetTerminalHistoryIfStored(history)
    }

    func removeFromTerminalHistory(_ command: String) {
        var history = terminalHistory
        history.removeAll { $0 == command }
        terminalHistory = history
        forgetTerminalHistoryIfStored(history)
    }

    private func forgetTerminalHistoryIfStored(_ history: [String]) {
        UserDefaults.standard.set(history, forKey: PreferenceKeys.terminalHistory)
    }

    /// With no session up a note has nowhere to go, which is right: no Mac did anything.
    func append(note: String) { activeSession?.append(note: note) }

    func refreshTerminals() { activeSession?.refreshTerminals() }

    func refreshAgents() { activeSession?.refreshAgents() }

    /// Before the Mac has said, what it said last time, else nothing for a Mac that will answer: a list of all that then shrank was a blink. A Mac that cannot say gets every agent.
    var availableAgents: [TerminalAgent] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "Peering.showAllAgents") { return TerminalAgent.all }
        #endif
        guard let session = activeSession else { return TerminalAgent.all }
        guard let installed = session.knownInstalledAgents else {
            return session.hostSupportsAgentList ? [] : TerminalAgent.all
        }
        return TerminalAgent.all.filter { installed.contains($0.command) }
    }

    var isAwaitingAgentList: Bool {
        guard let session = activeSession else { return false }
        return session.hostSupportsAgentList && session.knownInstalledAgents == nil
    }

    var canOpenAnotherShell: Bool { activeSession?.canOpenAnotherShell ?? true }

    var runningShellTargetID: UUID? { activeSession?.runningShellTargetID }

    /// Written back to nil when taken, so the same arrival is not opened twice.
    var newTerminalID: UUID? {
        get { activeSession?.newTerminalID }
        set { activeSession?.newTerminalID = newValue }
    }

    func createTerminal() { Analytics.featureUsed(.terminalCreated); activeSession?.createTerminal() }

    func createTerminal(inDirectory path: String?) { Analytics.featureUsed(.terminalCreated); activeSession?.createTerminal(inDirectory: path) }

    func runInNewTerminal(_ command: String) { Analytics.featureUsed(.terminalRunCommand); activeSession?.runInNewTerminal(command) }

    func renameTerminal(_ id: UUID, to name: String) { Analytics.featureUsed(.terminalRenamed); activeSession?.renameTerminal(id, to: name) }

    func selectTerminal(_ id: UUID) { activeSession?.selectTerminal(id) }

    func sendTerminalInput(_ text: String, to id: UUID, appendReturn: Bool = true) {
        activeSession?.sendTerminalInput(text, to: id, appendReturn: appendReturn)
    }

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        activeSession?.sendTerminalBytes(bytes, to: id)
    }

    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        activeSession?.resizeTerminal(id, columns: columns, rows: rows)
    }

    func closeTerminal(_ id: UUID) { Analytics.featureUsed(.terminalClosed); activeSession?.closeTerminal(id) }

    // MARK: - The active Mac's file browser

    var hostSupportsFileBrowser: Bool { activeSession?.hostSupportsFileBrowser ?? false }

    var browserID: UUID? { activeSession?.browserID }

    func openFileScope() { activeSession?.openFileScope() }

    var browserPath: String? {
        guard let session = activeSession else { return nil }
        return session.browsingPath(for: session.browserID)
    }

    func setBrowserPath(_ path: String?) {
        guard let session = activeSession else { return }
        session.setBrowsingPath(path, for: session.browserID)
        if let path, let mac = session.hostName { FolderMemory().remember(path, for: mac) }
    }

    var rememberedFilesFolder: String? {
        activeSession?.hostName.flatMap { FolderMemory().folder(for: $0) }
    }

    func forgetFilesFolder() {
        if let mac = activeSession?.hostName { FolderMemory().forget(for: mac) }
    }

    func browsingPath(for id: UUID) -> String? { activeSession?.browsingPath(for: id) }

    func setBrowsingPath(_ path: String?, for id: UUID) {
        activeSession?.setBrowsingPath(path, for: id)
    }

    func listDirectory(_ path: String?, sessionID id: UUID) {
        activeSession?.listDirectory(path, sessionID: id)
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        Analytics.featureUsed(.filePreviewed)
        activeSession?.previewFile(path, sessionID: id)
    }

    func closePreview() { activeSession?.closePreview() }

    func saveFile(_ text: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileSaved)
        activeSession?.saveFile(text, sessionID: id)
    }

    /// The chat screen's attachments go into the folder the agent works in, not whatever a browser is looking at.
    func uploadFile(_ url: URL, toFolder folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileUpload)
        activeSession?.uploadFile(url, toFolder: folder, sessionID: id)
    }

    func uploadFile(_ url: URL, sessionID id: UUID) {
        activeSession?.uploadFile(url, sessionID: id)
    }

    func uploadItems(_ urls: [URL], sessionID id: UUID) {
        Analytics.featureUsed(.folderUpload)
        activeSession?.uploadItems(urls, sessionID: id)
    }

    func folderProgress(sessionID id: UUID) -> String? {
        activeSession?.folderProgress(sessionID: id)
    }

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileCreated)
        activeSession?.createEntry(name, kind: kind, in: folder, sessionID: id)
    }

    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileRenamed)
        activeSession?.renameEntry(entry, to: name, in: folder, sessionID: id)
    }

    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileDeleted)
        activeSession?.deleteEntry(entry, in: folder, sessionID: id)
    }

    func directory(_ path: String?, sessionID id: UUID) -> RemoteDirectory? {
        activeSession?.directory(path, sessionID: id)
    }

    func isLoadingDirectory(_ path: String?, sessionID id: UUID) -> Bool {
        activeSession?.isLoadingDirectory(path, sessionID: id) ?? false
    }

    func browseFailure(_ path: String?, sessionID id: UUID) -> String? {
        activeSession?.browseFailure(path, sessionID: id)
    }

    func isChangingFile(sessionID id: UUID) -> Bool {
        activeSession?.isChangingFile(sessionID: id) ?? false
    }

    func changeFailure(sessionID id: UUID) -> String? { activeSession?.changeFailure(sessionID: id) }

    func isWritingFile(sessionID id: UUID) -> Bool {
        activeSession?.isWritingFile(sessionID: id) ?? false
    }

    func saveFailure(sessionID id: UUID) -> String? { activeSession?.saveFailure(sessionID: id) }

    func uploadFailure(sessionID id: UUID) -> String? { activeSession?.uploadFailure(sessionID: id) }

    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    var activeSourceTitle: String? { activeSession?.activeSourceTitle }

    var capturePixelSize: CGSize? { activeSession?.capturePixelSize }

    var capturePointSize: CGSize {
        activeSession?.capturePointSize ?? CGSize(width: 1512, height: 982)
    }

    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        PictureIdentity.forStream(
            config,
            catalog: catalog,
            source: mosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }
}

extension ClientSession.Phase {
    /// The three phases with no live connection are where a latched modifier or pressed button has no way left to be released.
}

extension Modifiers {
    /// Symbols, not words: read next to the same glyphs the buttons use.
    var label: String {
        var names: [String] = []
        if contains(.command) { names.append("⌘") }
        if contains(.shift) { names.append("⇧") }
        if contains(.option) { names.append("⌥") }
        if contains(.control) { names.append("⌃") }
        return names.isEmpty ? String(localized: "a modifier") : names.joined()
    }
}

private nonisolated final class WeakWire: @unchecked Sendable {
    weak var wire: ClientSession?
}
