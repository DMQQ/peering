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
///
/// Not a preference: the two are different protocols on the wire. ``unicode`` sends
/// ``RemoteCommand/textInput(_:)``, which the host injects as text, so emoji and CJK arrive
/// intact but no physical keycode is ever pressed and ⌘S or ⌘Tab never fires. ``keycode``
/// presses real macOS virtual keycodes, so shortcuts work but a character with no keycode on
/// the Mac's layout cannot be typed.
enum KeyboardMode: String, CaseIterable, Identifiable {
    case unicode
    case keycode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unicode: return "Unicode"
        case .keycode: return "Keycode"
        }
    }

    var explanation: String {
        switch self {
        case .unicode:
            return "Sends text. Emoji and non-Latin scripts work; Mac shortcuts like ⌘S do not."
        case .keycode:
            return "Sends real key presses with modifiers. Shortcuts work; characters outside the Mac's layout cannot be typed."
        }
    }
}

/// One macro button: a keycode with modifiers, sent as a press and a release.
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
    /// When this process's model came up, for ``resumeTheLastMacIfNothingIsOpen()``'s own grace.
    let launchedAt = Date()

    /// Which way a session's control connection is carried.
    ///
    /// Declared on ``MacSession`` and merely named here, because the answer is a property of one
    /// connection rather than of the app: one Mac can be on this network while another is on the
    /// other side of the country.
    typealias ConnectionPath = MacSession.ConnectionPath

    /// A file on its way to one Mac, and the change asked for on one Mac. Named here as well as on
    /// ``MacSession`` for the same reason ``ConnectionPath`` is.
    typealias FileWrite = MacSession.FileWrite
    typealias FileChange = MacSession.FileChange

    /// A preset for the picture's bitrate, or the app's own choice of one.
    ///
    /// Declared in ``MacCastKit`` and merely named here: it is storage policy rather than app state,
    /// and all of it can be checked without an app bundle.
    typealias StreamQuality = MacCastKit.StreamQuality

    // MARK: - The sessions

    /// Every Mac that has been connected to in this launch. ``connect(to:)`` replaces the list with
    /// the session it starts, so it holds one at a time; the per-Mac state lives on these objects.
    /// See ``MacSession``.
    private(set) var sessions: [MacSession] = []

    /// Which session the screens are about, and the one input goes to.
    ///
    /// Assigned as the user moves between Macs, and never chosen directly: the tab strip moves it,
    /// and input follows it.
    var activeSessionID: UUID?

    /// The session the app is showing, or `nil` when there is not one. Every per-Mac property below
    /// reads and writes through it.
    var activeSession: MacSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// Whether that Mac is on screen, or the user has stepped back to the picker with it still
    /// connected.
    ///
    /// **A session that is open and a session being watched are two things, and this is the second
    /// one.** The picker could not tell them apart: a live session took the whole screen until it was
    /// ended, so looking at the list of Macs meant giving up the one you were on. The state itself
    /// costs one flag; what keeps the session alive is that nothing else changes while it is set.
    /// The control channel, the shells, the clipboard and the sleep assertion all stay, and only the
    /// picture stops (see ``MacSession/setPicturePaused(_:)``), which is what a Mac nobody is looking
    /// at should be doing with its battery and its bandwidth.
    ///
    /// Put back by every route that shows a session: ``returnToSession()``, ``activateSession(_:)``,
    /// ``connect(to:replacing:)`` and ``disconnect(deliberate:)``.
    var isSessionOnScreen = true

    /// Whether the picture was stopped by stepping away rather than by the user's own switch.
    ///
    /// Held apart from ``MacSession/picturePaused`` so that coming back does not undo a pause
    /// somebody asked for: only the pause this took is taken back. Internal rather than private so
    /// the end of a session can clear it with the rest of the session state. See
    /// ``stepAwayFromSession()``.
    var pausedBySteppingAway = false

    /// Makes one session the Mac the app is showing, and tells the Macs about it.
    ///
    /// The cheap one: the handshake, the pairing, the sockets, the shells and the sleep assertion all
    /// stay where they are, and only which Mac's picture is decoded changes. The Mac being left is
    /// asked to pause, which is what keeps it from spending its battery on frames nobody is looking
    /// at.
    ///
    /// A no-op for the session already on screen, deliberately: asking a Mac for its picture again
    /// would blink it. The one case that is not a no-op is the Mac already in hand *with the screen
    /// away from it*, which is the whole of what ``returnToSession()`` does.
    func activateSession(_ id: UUID) {
        guard id != activeSessionID else {
            returnToSession()
            return
        }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Stopped before the switch rather than after: otherwise both Macs stream for however long
        // the handover takes.
        activeSession?.setPicturePaused(true)
        let left = activeSession
        activeSessionID = id
        session.setPicturePaused(false)
        // Arriving at a Mac is being on its screen, whatever the last one's screen was doing, and a
        // pause taken for stepping away went with that screen. See ``isSessionOnScreen``.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // The sound follows the tab: a player built for the Mac on screen goes on playing after the
        // user has looked away unless it is told. See ``MacSession/shouldPlayAudio``.
        left?.refreshAudioMuteState()
        session.refreshAudioMuteState()

        // The card follows the tab, name and clock and all. Its own entry point rather than a phase
        // change: the Mac being arrived at has its own clock. See
        // ``SessionActivity/followActiveSession``.
        SessionActivity.shared.followActiveSession(
            hostName: session.hostName ?? "the Mac",
            startedAt: session.sessionStartedAt,
            phase: session.phase,
            reconnecting: session.isReconnecting,
            path: MacSession.activityPath(session.connectionPath),
            sessionCount: openSessions.count
        )
        // The widget's idea of which Mac is in hand. See ``publishOpenMacs()``.
        publishOpenMacs()
    }

    /// Puts the picture away and shows the picker, leaving the Mac connected.
    ///
    /// The session stays exactly as it is: what this changes is one flag, the frames the Mac is asked
    /// for, and the sound. Nothing is sent that could not be sent back, which is the difference
    /// between this and ``disconnect(deliberate:)`` — and it is why the pill draws them as two
    /// controls rather than one.
    ///
    /// The pause is taken only if the user had not already asked for one, and only if nothing else is
    /// watching: a picture somebody stopped by hand stays stopped when they come back to it, and a
    /// picture floating in a Picture in Picture window is somebody still watching, so it goes on
    /// arriving for the window rather than freezing in it. A Mac too old to be asked for silence goes
    /// on streaming at nobody, which is the honest failure: the session works and the frames are
    /// wasted.
    func stepAwayFromSession() {
        guard isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = false
        if !session.picturePaused, !session.isWatched {
            pausedBySteppingAway = true
            session.setPicturePaused(true)
        }
        session.refreshAudioMuteState()
    }

    /// Brings the live session back on screen, and the picture back with it.
    ///
    /// The other half of ``stepAwayFromSession()``, and the same shape as arriving at a Mac in
    /// ``activateSession(_:)``: the frames are asked for again only if stepping away was what
    /// stopped them.
    func returnToSession() {
        guard !isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = true
        if pausedBySteppingAway {
            pausedBySteppingAway = false
            session.setPicturePaused(false)
        }
        session.refreshAudioMuteState()
    }

    /// The Macs that are open, in the order they were opened.
    ///
    /// Not the same list as ``sessions``: an ended session is kept until the next one arrives so its
    /// failure can still be read, and a Mac nobody is connected to is not a tab.
    var openSessions: [MacSession] { sessions.filter(\.isLive) }

    /// Whether any Mac is open, which is the question the picker and the gate both ask.
    var hasOpenSession: Bool { !openSessions.isEmpty }

    /// Whether another Mac may be opened on this plan.
    ///
    /// The first Mac is free on every plan, so the question is never "is this paid" but "is this
    /// paid, or is this the first one".
    var canAddAnotherSession: Bool {
        storeManager.access.includes(.concurrentSessions) || openSessions.isEmpty
    }

    /// The most Macs the app will hold open at once.
    ///
    /// A ceiling on the phone rather than on the service: each open Mac costs this device a control
    /// connection, a keepalive and a sleep assertion, and the phone is what pays for servicing them.
    static let sessionCeiling = 4

    // MARK: - Connection state

    var phase: ClientSession.Phase {
        get { activeSession?.phase ?? .idle }
        set { activeSession?.phase = newValue }
    }
    var hosts: [DiscoveredHost] = []

    /// The Bonjour endpoint each Mac was last reached at on this network, by host ID.
    ///
    /// **Because the path is re-derived from Bonjour at the moment of the dial, and that is the one
    /// moment Bonjour cannot be relied on.** A drop that follows a backgrounding is a drop whose mDNS
    /// results went stale while the app was suspended; a re-browse takes seconds and the reconnect
    /// ladder's first rung is one. In memory rather than on disk: an endpoint that survived a relaunch
    /// is an address from whatever network the phone was on then.
    private var lastLANHosts: [String: DiscoveredHost] = [:]

    /// The endpoint a Mac was last reached at, if this launch has reached it on this network.
    func rememberedLANHost(_ hostID: String) -> DiscoveredHost? {
        lastLANHosts[hostID]
    }

    /// What one dial is allowed to take when nothing more specific is asked for, matching
    /// `ClientSession.connect`'s own default.
    static let standardConnectTimeout: TimeInterval = 10

    /// How long the rung that dials a remembered address may take. Short, because it is the one dial
    /// whose address may be wrong: a Mac that has moved costs this much before the relay is tried.
    static let rememberedPathTimeout: TimeInterval = 3

    /// Whether each paired Mac is registered with the relay, by host ID.
    ///
    /// Three states, which is why it is not a `Set`: `true` and `false` are the relay's answers, and
    /// an absent key is nobody having found out. The screen draws the last two differently.
    var relayPresence: [String: Bool] = [:]
    /// `nil` = never polled. `true` = relay answered last poll. `false` = relay was unreachable.
    var relayReachable: Bool? = nil

    /// What this phone knows about whether a paired Mac can be reached right now.
    ///
    /// Not a `Bool`: "not reachable" is two different facts, and only one of them is about the Mac.
    enum Reachability: Equatable {
        /// On this network. Bonjour can see it, so it is up and it is addressable directly.
        case nearby
        /// Registered with the relay, so it is up and reachable from anywhere.
        case viaRelay
        /// The relay says it is not registered. Not quite "switched off": a Mac can be awake on its
        /// own network while registered nowhere, and that one is out of reach.
        case notRegistered
        /// Nobody has found out, or the asking did not come back.
        case unknown

        var isReachable: Bool {
            switch self {
            case .nearby, .viaRelay: return true
            case .notRegistered, .unknown: return false
            }
        }
    }

    /// The three facts, in the order that decides them: this network, then the relay, then nothing.
    func reachability(ofHost hostID: String) -> Reachability {
        if hosts.contains(where: { $0.id == hostID }) { return .nearby }
        switch relayPresence[hostID] {
        case true?: return .viaRelay
        case false?: return .notRegistered
        case nil: return .unknown
        }
    }
    var browseStatus = "Looking for Macs on this network…"
    var tlsDescription: String?

    var sessionHistory: [ClientSessionRecord] = SessionHistoryStore.load()
    var pairedHostIDs: [String] = []

    /// The bitrate preset; redrawing on change requires a stored var, not a UserDefaults read.
    var streamQuality: StreamQuality = SessionModel.storedQuality
    /// The level to come back to when the rate is taken over by hand again.
    ///
    /// Seeded from the stored preference, so that Automatic to Manual returns to the level last saved
    /// rather than to whatever the policy happens to be sitting on. `nil` when the stored value is
    /// automatic, since there is no manual level to come back to.
    var lastManualQuality: StreamQuality? = .storedManualLevel()


    // MARK: - Clipboard
    /// The most recently received host clipboard. `nil` until the first pull.
    ///
    /// A payload rather than a string: the Mac's pasteboard holds a picture as readily as a line of
    /// text, and both arrive the same way. See ``ClipboardPayload``.
    var hostClipboard: ClipboardPayload? {
        get { activeSession?.hostClipboard }
        set { activeSession?.hostClipboard = newValue }
    }

    /// Whether a clipboard pull is in flight.
    var clipboardPulling: Bool {
        get { activeSession?.clipboardPulling ?? false }
        set { activeSession?.clipboardPulling = newValue }
    }

    // MARK: - Wake-on-LAN
    /// Hardware MAC addresses reported by the host's ServerHello. Stored by host ID.
    var hostMACAddresses: [String: [String]] = {
        guard let data = UserDefaults.standard.data(forKey: "hostMACAddresses"),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    // MARK: - Audio

    /// The player for the Mac's audio, one per session. One Mac's sound at a time: two Macs' worth
    /// arriving at one phone would be two things playing at once.
    var audioPlayer: RemoteAudioPlayer? {
        get { activeSession?.audioPlayer }
        set { activeSession?.audioPlayer = newValue }
    }

    /// Whether the Mac's own audio is played here, or dropped. On by default.
    ///
    /// The channel carries what the Mac plays and also every system sound it makes in response to
    /// this phone's input, so the alert for a chord that leads nowhere is heard a round trip after
    /// the gesture.
    var hostAudioMuted = UserDefaults.standard.object(forKey: PreferenceKeys.hostAudioMuted) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hostAudioMuted, forKey: PreferenceKeys.hostAudioMuted)
            // Every Mac, not the one on screen: a Mac behind the one being looked at is exactly the
            // one that would keep playing unnoticed. See ``MacSession/shouldPlayAudio``.
            for session in sessions { session.refreshAudioMuteState() }
        }
    }

    /// Whether the Mac's audio comes out of this phone: the switch and the plan together.
    ///
    /// A gate on the switch alone would not be enough, because the audio keeps arriving over a
    /// connection the user already has: a free user who never touches anything would still hear it
    /// unless the player is told, so this is asked where the player is configured.
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

    /// Every folder the active Mac has listed, keyed by the terminal and the path.
    var directories: [RemoteDirectoryKey: RemoteDirectory] {
        get { activeSession?.directories ?? [:] }
        set { activeSession?.directories = newValue }
    }

    /// Which folder each terminal's browser is showing.
    var browsingPaths: [UUID: String] {
        get { activeSession?.browsingPaths ?? [:] }
        set { activeSession?.browsingPaths = newValue }
    }

    /// Folders asked for and not yet answered, which is what a spinner on the panel is reading.
    var pendingDirectories: Set<RemoteDirectoryKey> {
        get { activeSession?.pendingDirectories ?? [] }
        set { activeSession?.pendingDirectories = newValue }
    }

    /// Why a folder could not be listed, until it lists.
    var browseFailures: [RemoteDirectoryKey: String] {
        get { activeSession?.browseFailures ?? [:] }
        set { activeSession?.browseFailures = newValue }
    }

    /// The file being shown, and how much of it has arrived.
    var filePreview: RemoteFilePreview? {
        get { activeSession?.filePreview }
        set { activeSession?.filePreview = newValue }
    }

    /// A command waiting for the shell that will run it.
    var pendingRun: String? {
        get { activeSession?.pendingRun }
        set { activeSession?.pendingRun = newValue }
    }

    /// Files on their way to the Mac, by the terminal they are being written through.
    var writes: [UUID: FileWrite] {
        get { activeSession?.writes ?? [:] }
        set { activeSession?.writes = newValue }
    }

    /// Why a write did not land, by the terminal it was made through, and kept apart by door.
    var saveFailures: [UUID: String] {
        get { activeSession?.saveFailures ?? [:] }
        set { activeSession?.saveFailures = newValue }
    }
    var uploadFailures: [UUID: String] {
        get { activeSession?.uploadFailures ?? [:] }
        set { activeSession?.uploadFailures = newValue }
    }

    /// Changes in the air, by the terminal they were asked through.
    var changes: [UUID: FileChange] {
        get { activeSession?.changes ?? [:] }
        set { activeSession?.changes = newValue }
    }

    /// Why a change did not happen, by the terminal it was asked through.
    var changeFailures: [UUID: String] {
        get { activeSession?.changeFailures ?? [:] }
        set { activeSession?.changeFailures = newValue }
    }

    /// What each trusted Mac is called, by the ID its pin is keyed by. The pin store knows only the
    /// ID, and the handshake is the only moment the client is told both, so it is the only moment
    /// this can be recorded.
    var hostNames: [String: String] = [:]

    /// The ID a first pairing was dialled by, while one is in flight or has just failed.
    ///
    /// The relay answers for whatever holds the ID it was given, so "not registered" and "you typed
    /// one digit wrong" arrive as the same message, and only the ID the user asked for tells them
    /// apart. Cleared by every other connect, so it can never caption another kind of session. See
    /// ``connect(to:)``.
    var remotePairingHostID: String?

    /// When each trusted Mac was last successfully connected to, keyed by host ID.
    var lastConnectedAt: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "hostLastConnectedAt"),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    /// The failure to show the user, if the session is in one. The phase carries it, and the picker
    /// needs it: without it a connection that failed instantly looks like a button that did nothing.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Names the user has chosen, which win over the name the Mac reports.
    ///
    /// Kept apart from ``hostNames`` rather than overwriting an entry in it: `hostNames` is rewritten
    /// from the Mac's own `ServerHello` on every connect, so a rename stored there would survive
    /// until the next handshake and then quietly revert.
    var customHostNames: [String: String] = [:]

    /// Set when the device's own identity could not be loaded: without a client certificate there is
    /// nothing for the Mac to pin, so everything else is moot.
    var identityFailure: String?

    // MARK: - User choices

    /// The address and port the manual-connect card is showing.
    ///
    /// Remembered across launches and deliberately not used to reconnect to anything: a stored IP is
    /// the thing that goes stale exactly when a network changes. They are kept so a Mac on a custom
    /// port does not have to be typed in again on every launch.
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

    /// What the joystick multiplies the pointer's travel by.
    ///
    /// A number rather than an index, so the label and the arithmetic read the same, and persisted
    /// because it is a property of the hand rather than of the session.
    var pointerSpeed: Double =
        UserDefaults.standard.object(forKey: PreferenceKeys.pointerSpeed) as? Double ?? 1

    var showKeyboard = false {
        didSet {
            // Putting the keyboard away ends the line this bar was keeping: what it holds is the
            // sentence the keyboard has typed since it was last emptied, and with the keyboard gone
            // there is nothing left that would ever correct it. This is also the way out of a
            // preview that has drifted, which is otherwise a bar showing text with no way to clear
            // it: delete the characters, or put the keyboard down and pick it up again.
            if !showKeyboard { typedPreview = "" }
            keyboardOpenedByFocus = false
        }
    }

    /// Whether the keyboard is up because a Mac text field took focus, so it may close itself
    /// again when focus leaves. A keyboard the user opened is theirs to close.
    var keyboardOpenedByFocus = false

    /// Opens the keyboard when the Mac's focus lands in a text field, and closes it on the way out
    /// if it was opened that way. See ``TextFocus``.
    func textFocusChanged(_ focus: TextFocus) {
        let enabled = UserDefaults.standard.object(forKey: PreferenceKeys.opensKeyboardForTextFields) as? Bool ?? true
        guard enabled, !isObserving, !isShowingMosaic else { return }
        if focus.isEditable {
            guard !showKeyboard else { return }
            showKeyboard = true
            keyboardOpenedByFocus = true
        } else if keyboardOpenedByFocus {
            showKeyboard = false
        }
    }

    /// What the keyboard has typed into the Mac since the line was last committed.
    ///
    /// The bar's own record rather than the Mac's, which is why it is emptied by Return, by a
    /// newline arriving as text, and by the keyboard being put away: every one of those is this
    /// side deciding it is no longer describing the same line. Anything that *sends* characters
    /// has to go through ``handleTypedText(_:)`` and ``handleBackspace()`` — a keycode sent
    /// directly leaves this showing a character the Mac has already lost.
    var typedPreview = ""

    // MARK: - Purchase

    let storeManager = StoreManager()
    /// Why the paywall is up, or `nil` when it is not. Shows `PaywallView`.
    ///
    /// The reason travels with the flag rather than beside it, so the screen showing the paywall never
    /// has to guess which door the user came through.
    var paywallReason: PaywallView.Reason?

    /// The plan whose allowance ran out under a live session, or `nil` when no session was cut.
    ///
    /// The one case where a session ends and nothing on screen says why: the relay stops splicing the
    /// moment the allowance is spent and says nothing, so this end sees a socket closed like any other
    /// and reconnects, and the reason first exists when that reconnect is refused with `quotaExceeded`.
    /// Carries the plan, because the sheet names the allowance the user was on. See
    /// ``relaySessionDropped``.
    var spentAllowance: RelayPlan?

    /// Whether a relay session has dropped since the last time the relay refused a connection.
    ///
    /// `quotaExceeded` looks identical whether the user tapped Connect into a spent allowance or the
    /// relay has just cut a running session, and only one of those is a wall the user walked into, so
    /// the difference is recorded before the refusal arrives.
    var relaySessionDropped = false

    /// Closes the explanation, and puts the app back where a session that has ended belongs.
    ///
    /// Closing alone is not enough: a session the relay cut is torn down as a failed reconnect, and a
    /// failed attempt during a resume is swallowed rather than shown, so the phase can be left sitting
    /// on a connecting state with nothing behind it. A session that is up is left alone.
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

    /// Watches the phone's own network so that a switch is answered at once rather than waited out.
    /// Created in ``start()``.
    private var networkWatcher: NetworkPathWatcher?
    let notifier = SessionNotifier.shared

    /// Whether the last thing Bonjour said was a failure. The browser replaces a dead one on its own,
    /// but a suspended app is not running to do it, so the foreground is the one moment worth
    /// restarting immediately.
    var browseFailed = false
    var identity: SelfSignedIdentity?
    var device = DeviceIdentity(id: "", name: "")

    /// The offer that is waiting for the screen change to finish. See
    /// ``SessionModel/offerSubscriptionIfDue(after:)``.
    ///
    /// A task rather than a timestamp, because what has to be cancellable is the showing and not the
    /// decision, and it doubles as the flag that stops a second offer being armed.
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

        // The renderer is the model's, and the session on screen is the one whose frames it shows.
        renderer.onFirstFrame = { [weak self] in
            self?.frameArrived += 1
        }
    }

    /// Bumped each time a frame of the stream the session just configured reaches the live layer.
    ///
    /// A hero transition's cue to let its frozen snapshot go: this is the moment the picture the
    /// app describes is actually decoded and ready, which a plain `@Observable` read of the
    /// renderer cannot answer, since the renderer runs off the main actor and is not observable
    /// itself. See ``isReadyToPlace(of:)``.
    var frameArrived = 0

    /// Whether the renderer has a frame of a stream of this size ready on the live layer.
    ///
    /// The size is what identifies the stream, because the order a frame and its config reach the
    /// main actor cannot be relied on.
    func isReadyToPlace(of size: CGSize) -> Bool {
        let snapshot = renderer.currentSnapshot
        return snapshot.configGeneration > 0
            && snapshot.readyGeneration == snapshot.configGeneration
            && snapshot.pixelWidth == Int(size.width)
            && snapshot.pixelHeight == Int(size.height)
    }

    // MARK: - Push token

    /// Whether the user has allowed banners, for the one row that reports it. Held here because
    /// reading it is an `await` on the system. See ``SessionNotifier/refreshAuthorization()``.
    private(set) var notificationsAuthorized = false

    /// "Yes", or the reason this phone cannot be reached with no session up. Nil when the device holds
    /// no push token and nothing went wrong saying why, which is a fresh install that has not yet been
    /// authorized. Read through the notifier rather than copied, because it is written from an
    /// app-delegate callback.
    var pushRegistration: String? {
        if notifier.remoteToken != nil { return "Yes" }
        return notifier.remoteTokenFailure
    }

    /// Re-reads the notification permission, from the one screen that shows it.
    func refreshNotificationAuthorization() async {
        notificationsAuthorized = await notifier.refreshAuthorization()
    }

    /// Sends the current APNs token to every session that is ready, or clears it when the plan does
    /// not include being told.
    ///
    /// This is the gate for the push half of the feature, and it is here rather than at the Mac: the
    /// Mac sends a notification to a token and knows nothing else about the user, so a phone that never
    /// hands one over cannot be reached on any plan.
    ///
    /// An empty registration is sent rather than skipped, and it is the message that forgets the token
    /// the Mac was given while the plan did include it, because a subscription that lapses is exactly
    /// the case this has to answer.
    ///
    /// Nothing is sent while the entitlement has not been read, so a subscriber is not stripped of the
    /// feature in the first moments of a launch.
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
        // Anything on the Lock Screen from a previous run describes a session this process did not
        // survive, and nothing else in this launch knows it is there.
        SessionActivity.shared.adoptOrphan()
        browser.onEvent = { [weak self] event in
            // Bound once, outside the `Task`: a `weak self` reference is a mutable variable, and
            // reading it from a closure that outlives this one is a data race.
            guard let self else { return }
            // HostBrowser reports from its own queue, and each of these touches observable state.
            Task { @MainActor in self.apply(event) }
        }

        // Started with the app rather than at the first drop: the watcher compares against the path
        // the last dial was made on, so one begun at a drop would call its first update a change.
        let watcher = NetworkPathWatcher()
        watcher.hasSomethingToPutBack = { [weak self] in
            self?.sessions.contains { $0.isResumingAfterDrop } ?? false
        }
        watcher.onUsableChange = { [weak self] in self?.networkChanged() }
        watcher.onPathChange = { [weak self] in self?.verifyLiveSessions() }
        networkWatcher = watcher
        watcher.start()
    }

    /// Asks the network watcher whether the path has moved since the last dial.
    ///
    /// For the moment a wait begins rather than the moment the network moves, which is the relay case.
    /// Deferred by a turn at the call site, because it can dial. See
    /// ``NetworkPathWatcher/judgeNow()``.
    func considerNetworkChange() {
        networkWatcher?.judgeNow()
    }

    /// The phone's network has changed to something that can carry a session, so dial now rather than
    /// wait out a backoff that was counted against a network which is gone.
    ///
    /// Only for a Mac that is on its way back: a path change with a working session is not a reason to
    /// dial anything, and one with no session at all is not either.
    ///
    /// The counter is deliberately not reset, which is what keeps the ladder finite on a phone whose
    /// network flaps between two cells. Dialling early costs a rung rather than the ladder.
    private func networkChanged() {
        for session in sessions where session.isResumingAfterDrop {
            session.stopReconnecting()
            session.resumeIfNeeded()
        }
    }

    /// Asks every connected Mac to answer now, so one whose connection died with the old network
    /// or with the app's suspension is redialled at once rather than after the silence watchdog.
    func verifyLiveSessions() {
        for session in sessions where session.phase == .ready {
            session.wire?.verifyStillAnswering()
        }
    }

    func startBrowsing() {
        browser.start()
    }

    func restartBrowsing() {
        browseStatus = "Looking for Macs on this network…"
        browser.stop()
        browser.start()
    }

    /// Whether a Mac is open, which is what the picker's rows are disabled by.
    ///
    /// Any Mac, not the one on screen: a row disabled by the active session's phase alone would be
    /// enabled the moment the user looked at a Mac that had finished, which is exactly when the gate is
    /// the thing standing between them and a connection.
    var isBusy: Bool { hasOpenSession }

    func connect(to target: ClientSession.Target) {
        connect(to: target, replacing: nil)
    }

    /// The Mac a target names, or `nil` for a literal address. Written out rather than asked of
    /// ``ClientSession/Target``, whose own answer to this is internal to `RemoteCore`.
    private static func hostID(of target: ClientSession.Target) -> String? {
        switch target {
        case .discovered(let host): return host.id
        case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
        case .address: return nil
        }
    }

    /// Opens a Mac, replacing one session if there is one to replace.
    ///
    /// - Parameter old: the session this attempt supersedes, or `nil` when it is a Mac being opened
    ///   from the picker. A replaced session is removed rather than left to be pruned, because its
    ///   ladder has just handed over and two entries for one Mac read as "it connected twice".
    /// - Parameter timeout: how long this attempt may take. Short only for the rung of a resume that
    ///   dials a remembered address.
    func connect(
        to target: ClientSession.Target,
        replacing old: MacSession?,
        timeout: TimeInterval = SessionModel.standardConnectTimeout,
        racingRelay relay: ClientSession.Target? = nil
    ) {
        CrashLog.note("dial \(Self.hostID(of: target) ?? "unknown")\(old == nil ? "" : ", replacing a session") · \(sessions.count) open")
        guard let identity, identityFailure == nil else { return }

        // A Mac that is already open is brought to the front rather than dialled again: two sessions to
        // one Mac would be two control channels and two clients on the Mac, for one phone. Every route
        // that names a Mac passes through here, so this is the one place it can be answered.
        //
        // Not for a ladder putting a Mac back: `old` is how it says so.
        if old == nil, let hostID = Self.hostID(of: target),
           let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }

        // A Mac being dialled is a Mac the user wants to look at, so the screen goes to it from the
        // first frame of the connecting card: a session stepped away from and then dialled again
        // must not leave the picker up behind the card. See ``isSessionOnScreen``.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // The gate, at the one place every route passes through: a gate drawn on one door cannot be
        // walked past by another. See ``PlanCapability/concurrentSessions``.
        //
        // A ladder putting a Mac back is deliberately not gated: that Mac is already open and the plan
        // was checked when it was, so asking again would end a paid session mid-reconnect.
        if old == nil, hasOpenSession, !canAddAnotherSession {
            paywallReason = .feature(.concurrentSessions)
            return
        }
        // Said rather than silently refused: the ceiling is a fact about this phone rather than the
        // user's plan, and a tap that did nothing would read as the app being broken.
        if old == nil, openSessions.count >= Self.sessionCeiling {
            append(note: "This device holds \(Self.sessionCeiling) Macs open at once. Close one to open another.")
            return
        }

        // Remembered for the home-screen widget, which can offer to connect but has no way of knowing
        // to what. Written twice on purpose: the app reads its own defaults, and the widget can only
        // see the shared container. See ``reconnectToLastHost()``.
        UserDefaults.standard.set(target.displayName, forKey: Self.lastHostNameKey)
        SharedStore.lastHostName = target.displayName
        // A widget is not a live view and is not told anything, so without this it goes on showing the
        // previous Mac until the system next refreshes it.
        WidgetCenter.shared.reloadAllTimelines()

        // An attempt from the backoff timer would race this one and start a second session.
        stopReconnecting()
        // A session that is already up is torn down rather than replaced: assigning over it leaves the
        // first connection running with nothing holding it, so the peer sees it drop mid-handshake,
        // which with a retry following it is a loop rather than a session. The object below replaces it,
        // and the events the old connection is still emitting have nothing left to land on, which
        // describes a Mac nobody is looking at any more.
        activeSession?.connectTask?.cancel()
        activeSession?.connectTask = nil
        activeSession?.wire?.disconnect()
        // The user has just asked to reach a Mac, which is the first moment "tell you when it needs
        // you?" means anything.
        notifier.prepareForFirstConnect()

        // The new session: every per-Mac fact below is set on it rather than on the model, and the
        // screens go on reading them through the forwarders.
        let session = MacSession(model: self, renderer: renderer)

        // Cleared for every new session, whatever the target: a punched path belongs to the session
        // that proved it, the NAT mapping behind it can be gone by the next one, and a stale `true`
        // would have the app reporting a direct path it is not using.
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
            // Same reasoning as the literal address below: nothing has been proven to be this Mac yet,
            // so nothing is remembered as "the last Mac". The handshake writes the ID it actually
            // reached, and a half-typed ID left here would be dialled again by the reconnect ladder.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        case .address:
            session.connectionPath = .direct
            remotePairingHostID = nil
            // The handshake replaces this with the server's real ID; keeping a different Mac's ID
            // during that window could make an automatic retry dial the relay for the wrong machine.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        }
        // Fresh for the path this session just chose: the policy's tier is tuned per path.
        session.autoQualityPolicy = AutoQualityPolicy(path: session.autoQualityPath)
        session.lastAutoDroppedFrames = 0

        // Two facts belong to the Mac rather than to this attempt at reaching it, so they are carried
        // across a dial of that Mac and only of that Mac. Everything else above is the connection's.
        //
        // `hasBeenReady` tells a resume apart from a first connection: the ladder builds a new object,
        // so without it a Mac that dropped and is being put back is indistinguishable from one being
        // opened for the first time, and the connecting theatre goes back on screen for a network blip.
        //
        // `reconnectAttempt` is carried because the counter lives on the object and the object is
        // replaced on every attempt: without it a Mac that keeps failing stays on the first rung for as
        // long as it keeps failing.
        // The third fact of the same kind, and the one that cannot be carried from `old`: a cold
        // launch's restoration is the resume with no session behind it, so the intent arrives on the
        // model and is handed to the object being built. See ``MacSession/isComingBack``.
        session.isComingBack = isResuming

        if let old, let targetID = target.hostID, targetID == old.hostID {
            session.hasBeenReady = old.hasBeenReady
            session.reconnectAttempt = old.reconnectAttempt
            // And the clock the window is measured on, for the same reason as the counter: the run
            // of attempts is one run however many objects it is made of.
            session.reconnectingSince = old.reconnectingSince

            // And which source was on screen, because the screen is staying up: the Mac goes on
            // capturing the same display or window across a client reconnect, so a session that forgot
            // would have ``PictureIdentity`` read the picture as a different one and ``RemoteScreen``
            // reset the zoom and the pan, which is exactly the state a resume is meant to preserve.
            //
            // The catalogue itself is deliberately not carried: the Mac sends it again on `.ready`, and
            // a stale one naming sources that are gone is worse than a moment without one.
            session.activeSourceID = old.activeSourceID

            // **The arrangement, for the same reason, and the one this used to leave behind.** The
            // choices, not `isAskingForMosaic` or `askedMosaicLayout`: those are written as a side
            // effect of asking (see `SessionModel/selectSource(_:)`), and the reconnect's own
            // catalogue-triggered re-ask (`pendingSourceReassertion`) is what writes them again, from
            // these. Left uncarried, `activeSourceID` went on naming the arrangement while nothing
            // else on the new object agreed it was one — no borders, no tap to open a tile, no way
            // back — because a mosaic built from zero choices is not a mosaic at all.
            session.mosaicChoices = old.mosaicChoices

            // The renderer and this screen survive a reconnect, so the description of the picture
            // they are still showing has to survive with them. A fresh session used to forget this
            // while leaving the final mosaic frame visible; until another matching config happened
            // to arrive, the grid looked intact but had no mosaic overlay or tile hit targets.
            // The next source-tagged config remains authoritative and will replace this value when
            // the host actually changes pictures.
            session.pictureMosaicLayout = old.pictureMosaicLayout
        }

        // **The episode begins with the dial that starts it, not only with a rung.** A restoration
        // and the relay-to-LAN hand-over dial once with no ladder under them, so a dial that never
        // answers is otherwise bounded by nothing at all. A rung of a ladder already carries its
        // clock, which is why this only starts one. See ``SessionModel/reconnectWindow``.
        if isResuming, session.reconnectingSince == nil {
            session.reconnectingSince = Date()
        }

        session.hostName = target.displayName
        // Nothing else has to be cleared: everything below this line was this connection's, and this
        // connection is new.

        let race = relay == nil ? nil : DialRace(session: session)
        session.dialRace = race
        let (wire, gate) = makeWire(for: session, identity: identity, race: race)
        let resumeSource = old?.hostID == target.hostID ? old?.sourceToResume : nil
        wire.resumeSource = resumeSource
        session.wire = wire
        // The only place the container changes: a Mac that has finished is not a Mac anybody is
        // connected to and is let go of here, except a session still being retried, which has a ladder
        // running.
        if let old { sessions.removeAll { $0 === old } }
        sessions.removeAll { !$0.isLive }
        sessions.append(session)
        activeSessionID = session.id
        publishOpenMacs()

        // Whether a missing picture could be a network blocking video, which is a question about
        // *where* this Mac is: a Mac found over Bonjour is on this network, while the relay and a
        // typed-in address both cross networks nobody here controls.
        //
        // On the relay the picture already shares the control channel, so asking for it there is a
        // reduction in rate rather than a move.
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

    /// How long the LAN is dialled alone before the relay joins it. The LAN is free, so it gets
    /// the first chance, but a Mac on the same network answers in well under this.
    static let relayHeadStart: Duration = .milliseconds(300)

    /// A wire whose events reach `session`, held back behind a gate while it is in a race.
    private func makeWire(
        for session: MacSession,
        identity: SelfSignedIdentity,
        race: DialRace?
    ) -> (ClientSession, WireGate) {
        // Bound outside the closure, which runs on the network queue. Frames and configs go straight
        // to the renderer's own queue from there, in wire order: hopping them through the main actor
        // would put a 60 Hz stream behind layout.
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

    /// Everything pulled from the Mac this device has kept, newest first.
    ///
    /// The Mac's pasteboard holds one thing, so a second pull replaces the first, and this is the only
    /// place the earlier ones exist. Held here rather than in the panel because the panel is rebuilt
    /// every time it opens.
    var clipboardHistory: [ClipboardEntry] = SessionModel.loadClipboardHistory()

    /// How many pulls have been recorded, so a view can tell the list changed. The entries carry no
    /// identity to diff on and the text is arbitrary, including text that repeats.
    var clipboardHistoryCount = 0

    /// Text this app put on the iPhone's pasteboard or read from it, and the pasteboard's change
    /// count at the time. Reading the pasteboard asks the user, so this is the only text the
    /// clipboard panel can show for free, and only while the count still matches.
    var knownPhoneClipboard: (changeCount: Int, text: String)?

    // MARK: - Wake-on-LAN

    /// Sends a Wake-on-LAN magic packet for the given host ID, and says what came of it.
    ///
    /// A magic packet is a UDP broadcast that nobody acknowledges, so there is no answer to wait for
    /// and silence would be indistinguishable from a row that did nothing at all. The sentence also
    /// carries the limit that matters, that a broadcast does not leave the network it was sent on.
    func wakeHost(id: String) {
        let addresses = hostMACAddresses[id] ?? []
        let sent = addresses.filter { WakeOnLAN.send(to: $0) }.count
        guard sent > 0 else {
            append(note: addresses.isEmpty
                ? "No hardware address is on file for that Mac, so there is nothing to send a wake packet to."
                : "That Mac's stored hardware address could not be read, so no wake packet was sent.")
            return
        }
        append(note: "Wake packet sent to \(sent) hardware address\(sent == 1 ? "" : "es"). It can only reach a Mac on this network.")
    }

    var pendingHostID: String?

    /// Whether a trusted Mac has been asked for and not yet found.
    var isWaitingForHost: Bool { pendingHostID != nil }

    /// Whether a Mac may be reached through the relay, or only over the local network.
    ///
    /// The one thing in the app that can turn a feature off outright. Turning it off does not make
    /// anything more encrypted, since the relay cannot read what it carries anyway; it makes a
    /// different promise, that the Mac's device ID and the times it connects never reach a server at
    /// all, and that promise is only keepable if this gates every dial. All of them are gated:
    /// ``connectToTrusted(hostID:)``, ``reconnectToLastHost()``, ``resumeIfNeeded()`` and
    /// ``pairWithRemoteMac(hostID:)``.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)`, so that unset is distinguishable
    /// from off: the default is on, and `bool(forKey:)` would report that as `false`.
    var allowsRelay: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.allowRelay) as? Bool ?? true
    }

    static let lastHostNameKey = "Peering.lastHostName"
    static let lastHostIDKey = "Peering.lastHostID"

    static let resumeKey = "Peering.resumeWhenReachable"

    /// Set while a dropped session is being put back, so the Live Activity can say so rather than keep
    /// claiming a connection that is not there. Read off the session on screen, because the card
    /// describes one Mac. See ``MacSession/isReconnecting`` for why the ladder is per Mac.
    var isReconnecting: Bool {
        get { activeSession?.isReconnecting ?? false }
        set { activeSession?.isReconnecting = newValue }
    }

    /// Whether the Mac on screen dropped and is being put back. The rule is ``SessionResume``'s, and
    /// the screens ask here so that they read one answer. See ``MacSession/isResumingAfterDrop``.
    var isResumingAfterDrop: Bool { activeSession?.isResumingAfterDrop ?? false }

    /// Whether the Mac on screen is being put back, including the dial a cold launch makes.
    ///
    /// The forwarder the header reads, so that the two flags behind it are answered in one place.
    /// See ``MacSession/isBeingPutBack``.
    var isBeingPutBack: Bool { activeSession?.isBeingPutBack ?? false }

    /// How long to wait before each attempt at putting a dropped session back.
    ///
    /// Spread out, because the usual cause is the Mac being asleep or the network being briefly gone,
    /// and retrying every second for a minute spends a radio and a battery on an answer that has not
    /// changed. Five attempts over about forty seconds covers a Wi-Fi roam, a display waking and a Mac
    /// that was asleep and is not any more.
    static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(20),
    ]

    /// The same ladder for a Mac that dropped and is being put back, and it is short on purpose.
    ///
    /// A resume is silent: it shows a picture that has stopped moving and says nothing about it, so
    /// "still coming back" and "gone" look exactly alike, and the only difference the user can act on
    /// is how long they are asked to wonder. The first rung is nearly immediate, because a drop is
    /// now noticed as it happens rather than ten seconds later.
    ///
    /// The two ladders share a counter, which is why they are the same shape, biggest rung last:
    /// `reconnectAttempt` indexes into whichever one is in use and is carried across a dial, so the
    /// shorter list is simply the one that runs out sooner.
    static let resumeReconnectDelays: [Duration] = [
        .milliseconds(250), .seconds(1), .seconds(3),
    ]

    /// How long a Mac is given to come back before the app stops trying.
    ///
    /// The ladder's own end is a count of rungs, and a rung is a wait plus a dial that can take ten
    /// seconds to fail on its own, so "three rungs" is not a duration: a Mac that is gone can be
    /// waited on for half a minute, and a dial that never answers at all is not bounded by the
    /// count in any way. This is the bound that does not depend on the network answering, and it
    /// covers the restoration as well, which dials once and has no ladder to run out. Ten seconds
    /// is a Mac that has to be found and shake hands, and nothing more. See
    /// ``MacSession/giveUpAfterReconnectWindow()``.
    static let reconnectWindow: TimeInterval = 10

    var reconnectTask: Task<Void, Never>? {
        get { activeSession?.reconnectTask }
        set { activeSession?.reconnectTask = newValue }
    }

    var reconnectAttempt: Int {
        get { activeSession?.reconnectAttempt ?? 0 }
        set { activeSession?.reconnectAttempt = newValue }
    }

    /// Set while ``resumeIfNeeded()`` is connecting, so a failure it causes is retried by the ladder
    /// rather than reported.
    ///
    /// Coming back to the foreground is the case this exists for, and it is a race with the teardown of
    /// the session that just ended: that drop cancelled a socket moments ago and the kernel has not
    /// finished with it, so the connect is aborted before it starts. It clears itself in well under a
    /// second, and nobody asked for this attempt, so there is nobody to tell.
    var isResuming = false

    /// Clears ``isResuming`` when no Mac has an attempt of its own in flight any more.
    ///
    /// One flag for every Mac, so the last one to finish is the one that clears it, and "is one
    /// still running" is asked of the sessions rather than kept alongside. See
    /// ``MacSession/giveUpOnReconnecting()``.
    func clearResumingIfNothingIsUnderWay() {
        guard !sessions.contains(where: { $0.isResumingAfterDrop }) else { return }
        isResuming = false
    }

    var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var thisDeviceDescription: String { "\(device.name) · \(device.id)" }

    // MARK: - Input

    /// User-defined macros, persisted across launches. Shown after the built-in defaults.
    var customMacros: [Macro] = {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKeys.customMacros),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else {
            return []
        }
        return decoded
    }()

    /// All macros, built-in first, then custom.
    var allMacros: [Macro] { Macro.defaults + customMacros }

    // MARK: - Commands to the active Mac

    // Forwarders, like the properties above and for the same reason: a command belongs to a session,
    // and the panels have one Mac in hand. Where a command names a terminal, the ID came from the Mac
    // that made it and is unique across Macs, which is what routes it to the Mac that owns it rather
    // than to the one on screen.

    /// The commands sent from this phone, newest first.
    ///
    /// App-wide rather than per Mac: the Mac's own shell keeps the real history, and this is the
    /// shortlist the panel offers, so a command typed on one Mac is one the user is likely to want on
    /// the other.
    ///
    /// Stored rather than computed from the defaults, because the panel has to redraw when it changes
    /// and a computed property reading `UserDefaults` is a change nothing observes.
    var terminalHistory: [String] =
        UserDefaults.standard.stringArray(forKey: PreferenceKeys.terminalHistory) ?? []

    static let terminalHistoryLimit = 30

    /// Adds a command to the list the panel offers, and writes it down.
    ///
    /// De-duplicated, so a command run twice moves to the top rather than appearing twice, and capped,
    /// because this is a convenience and not a history file: the Mac's own shell keeps the real one.
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

    /// Takes one command back out, for the shell that said it did not exist.
    func removeFromTerminalHistory(_ command: String) {
        var history = terminalHistory
        history.removeAll { $0 == command }
        terminalHistory = history
        forgetTerminalHistoryIfStored(history)
    }

    private func forgetTerminalHistoryIfStored(_ history: [String]) {
        UserDefaults.standard.set(history, forKey: PreferenceKeys.terminalHistory)
    }

    /// Files a note against the Mac on screen. With no session up there is nowhere for one to go,
    /// which is right: a note describes what a Mac did, and there is no Mac to have done it. See
    /// ``MacSession/append(note:)``.
    func append(note: String) { activeSession?.append(note: note) }

    func refreshTerminals() { activeSession?.refreshTerminals() }

    /// Whether one more shell is allowed right now. See ``MacSession/canOpenAnotherShell``.
    var canOpenAnotherShell: Bool { activeSession?.canOpenAnotherShell ?? true }

    func createTerminal() { activeSession?.createTerminal() }

    func runInNewTerminal(_ command: String) { activeSession?.runInNewTerminal(command) }

    func renameTerminal(_ id: UUID, to name: String) { activeSession?.renameTerminal(id, to: name) }

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

    func closeTerminal(_ id: UUID) { activeSession?.closeTerminal(id) }

    // MARK: - The active Mac's file browser

    func browsingPath(for id: UUID) -> String? { activeSession?.browsingPath(for: id) }

    func setBrowsingPath(_ path: String?, for id: UUID) {
        activeSession?.setBrowsingPath(path, for: id)
    }

    func listDirectory(_ path: String?, sessionID id: UUID) {
        activeSession?.listDirectory(path, sessionID: id)
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        activeSession?.previewFile(path, sessionID: id)
    }

    func closePreview() { activeSession?.closePreview() }

    func saveFile(_ text: String, sessionID id: UUID) {
        activeSession?.saveFile(text, sessionID: id)
    }

    func uploadFile(_ url: URL, sessionID id: UUID) {
        activeSession?.uploadFile(url, sessionID: id)
    }

    /// Sends one or more things, folders and all, in one run.
    func uploadItems(_ urls: [URL], sessionID id: UUID) {
        activeSession?.uploadItems(urls, sessionID: id)
    }

    /// What a folder being sent through this shell is doing, or what the last one came to.
    func folderProgress(sessionID id: UUID) -> String? {
        activeSession?.folderProgress(sessionID: id)
    }

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        activeSession?.createEntry(name, kind: kind, in: folder, sessionID: id)
    }

    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        activeSession?.renameEntry(entry, to: name, in: folder, sessionID: id)
    }

    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
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

    /// Which path the rate policy is tuned for, read off the active session.
    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    var activeSourceTitle: String? { activeSession?.activeSourceTitle }

    /// The size of the captured content in pixels, if it is known.
    var capturePixelSize: CGSize? { activeSession?.capturePixelSize }

    /// The captured content's size in the Mac's *points*.
    var capturePointSize: CGSize {
        activeSession?.capturePointSize ?? CGSize(width: 1512, height: 982)
    }

    /// The picture a video config describes, named as far as this end can name it.
    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        PictureIdentity.forStream(
            config,
            catalog: catalog,
            source: mosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }
}

extension ClientSession.Phase {
    /// Whether a live connection is still behind this phase.
    ///
    /// The three that are not are the ones where anything the session was holding, a latched modifier
    /// or a pressed mouse button, has no way left to be released. Everything that cares asks here
    /// rather than listing the phases again.
}

extension Modifiers {
    /// Names the latched modifiers for the notes list. Symbols, not words: it is read next to the same
    /// glyphs the buttons are drawn with.
    var label: String {
        var names: [String] = []
        if contains(.command) { names.append("⌘") }
        if contains(.shift) { names.append("⇧") }
        if contains(.option) { names.append("⌥") }
        if contains(.control) { names.append("⌃") }
        return names.isEmpty ? "a modifier" : names.joined()
    }
}

private nonisolated final class WeakWire: @unchecked Sendable {
    weak var wire: ClientSession?
}
