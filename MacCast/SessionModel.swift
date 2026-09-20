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
/// The two modes are not a preference, they are different protocols on the wire, and the
/// difference is user-visible:
///
/// - ``unicode`` sends ``RemoteCommand/textInput(_:)``, which the host injects as Unicode
///   text. Layout-independent, so emoji, accented characters and CJK all arrive intact —
///   but a Mac shortcut that listens for a *physical* keycode (⌘S, ⌘Tab) never fires,
///   because no key was ever pressed.
/// - ``keycode`` sends ``RemoteCommand/keyDown(keyCode:modifiers:)`` and ``keyUp`` with real
///   macOS virtual keycodes, so shortcuts behave exactly as they do on a hardware keyboard.
///   The cost is that a character with no keycode on the Mac's layout cannot be expressed.
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
        // Keycodes are macOS virtual keycodes — the values `CGEvent` takes — not USB HID
        // usages and not characters. C is 8, V is 9, W is 13, Tab is 48, Space is 49.
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
        // Terminal / shell control sequences
        Macro(id: "ctrl-c",    title: "⌃C",     keyCode: 8,  modifiers: .control),
        Macro(id: "ctrl-z",    title: "⌃Z",     keyCode: 6,  modifiers: .control),
        Macro(id: "ctrl-d",    title: "⌃D",     keyCode: 2,  modifiers: .control),
        Macro(id: "ctrl-l",    title: "⌃L",     keyCode: 37, modifiers: .control),
        Macro(id: "ctrl-a",    title: "⌃A",     keyCode: 0,  modifiers: .control),
        Macro(id: "ctrl-e",    title: "⌃E",     keyCode: 14, modifiers: .control),
        Macro(id: "ctrl-r",    title: "⌃R",     keyCode: 15, modifiers: .control),
    ]
}

/// Everything the UI binds to.
///
/// One owner of the session, the identity and the renderer, so there is exactly one place
/// where a network event becomes observable state — and exactly one place to look when the
/// screen shows something that does not match what the Mac is doing.
@Observable
@MainActor
final class SessionModel {
    /// Which way a session's control connection is carried.
    ///
    /// **Declared on ``MacSession`` and merely named here**, because the answer is a property of
    /// one connection rather than of the app: one Mac can be on this network while another is on
    /// the other side of the country. The name is kept so that every screen that says one of the
    /// three cases out loud goes on saying the same thing.
    typealias ConnectionPath = MacSession.ConnectionPath

    /// A file on its way to one Mac, and the change asked for on one Mac.
    ///
    /// Named here as well as there for the same reason ``ConnectionPath`` is: they are the shapes
    /// the panels pass around, and the panels are talking about a Mac rather than being one.
    typealias FileWrite = MacSession.FileWrite
    typealias FileChange = MacSession.FileChange

    /// A preset for the picture's bitrate, or the app's own choice of one.
    ///
    /// **Declared in ``MacCastKit`` and merely named here.** It is storage policy rather than
    /// app state — the cases, the token each one is stored as, and the words the chip and the
    /// menu print — and all of it can be checked without an app bundle, which is why it lives
    /// where `swift test` can reach it. The nesting is kept so that every
    /// `SessionModel.StreamQuality` in the app, and `@AppStorage`'s own decoding of the token,
    /// still read the same.
    typealias StreamQuality = MacCastKit.StreamQuality

    // MARK: - The sessions

    /// Every Mac that has been connected to in this launch.
    ///
    /// **The container this whole stage exists for, and today it can only ever hold one.**
    /// ``connect(to:)`` replaces the list with the session it is starting, which is exactly what
    /// the app did when there was a single `session` property and no list at all. What has changed
    /// is where the per-Mac state lives: it is on these objects now, so a second one has somewhere
    /// to go. See ``MacSession``.
    private(set) var sessions: [MacSession] = []

    /// Which session the screens are about, and the one input goes to.
    ///
    /// Assigned beside ``sessions`` for now, and never a choice. Stage 3 is what turns it into
    /// one, by hanging a tab strip off it and sending `setVideoEnabled` on the way past.
    var activeSessionID: UUID?

    /// The session the app is showing, or `nil` when there is not one.
    ///
    /// Every per-Mac property below reads and writes through this, which is what keeps the
    /// screens compiling while the state underneath them moves.
    var activeSession: MacSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// Makes one session the Mac the app is showing, and tells the Macs about it.
    ///
    /// **The one operation the whole feature comes down to**, and the only one that is cheap:
    /// the handshake, the pairing, the sockets, the shells and the sleep assertion all stay
    /// exactly where they are. What changes is which Mac's picture is being decoded, and the
    /// asking is what keeps the other one from spending its battery and the operator's bandwidth
    /// on frames nobody is looking at.
    ///
    /// A no-op for the session already on screen, deliberately: asking a Mac for its picture
    /// again when nothing has changed would blink it, and a tab tapped twice is not a request to
    /// restart anything.
    func activateSession(_ id: UUID) {
        guard id != activeSessionID, let session = sessions.first(where: { $0.id == id }) else { return }
        // Stopped before the switch rather than after: the Mac being left should stop spending
        // at the moment it stops being looked at, and asking it afterwards would leave both
        // streaming for however long the handover takes.
        activeSession?.setPicturePaused(true)
        let left = activeSession
        activeSessionID = id
        session.setPicturePaused(false)

        // **The sound follows the tab.** A player built for the Mac on screen goes on playing
        // after the user has looked away unless it is told, and the Mac being arrived at is silent
        // until it is. Neither is a stream starting or stopping: this is one line on each player,
        // and the Mac behind keeps sending. See ``MacSession/shouldPlayAudio``.
        left?.refreshAudioMuteState()
        session.refreshAudioMuteState()
    }

    /// The Macs that are open, in the order they were opened.
    ///
    /// **What the tab strip draws and what the ceiling counts**, and not the same list as
    /// ``sessions``: a session that has ended is kept until the next one arrives so that its
    /// failure can still be read and its last figures copied into a diagnostics blob, and a Mac
    /// nobody is connected to is not a tab.
    var openSessions: [MacSession] { sessions.filter(\.isLive) }

    /// Whether any Mac is open, which is the question the picker and the gate both ask.
    var hasOpenSession: Bool { !openSessions.isEmpty }

    /// Whether another Mac may be opened on this plan.
    ///
    /// **The first Mac is free on every plan**, which is why this is not asked of
    /// ``StoreManager/access`` on its own. The question is never "is this paid": it is "is this
    /// paid, or is this the first one" — the same shape as ``canOpenAnotherShell``, and passed to
    /// the badge as `isIncluded` for the same reason.
    var canAddAnotherSession: Bool {
        storeManager.access.includes(.concurrentSessions) || openSessions.isEmpty
    }

    /// The most Macs the app will hold open at once.
    ///
    /// **A ceiling on the user's own phone rather than on the service**, and the number is
    /// deliberately low: every Mac open is a control connection, a keepalive and a sleep
    /// assertion held on a machine the user is not looking at, and past a handful the thing being
    /// spent is the battery of the phone that has to service them all. Four is more Macs than
    /// anybody works across at once and fewer than the number at which the cost stops being
    /// invisible.
    static let sessionCeiling = 4

    // MARK: - Connection state

    var phase: ClientSession.Phase {
        get { activeSession?.phase ?? .idle }
        set { activeSession?.phase = newValue }
    }
    var hosts: [DiscoveredHost] = []

    /// Whether each paired Mac is registered with the relay, by host ID.
    ///
    /// **Three states, and the third is the reason this is not a `Set`.** `true` is the relay
    /// saying it is there, `false` is the relay saying it is not, and *absent* is nobody having
    /// found out. The screen draws the last two differently, because one is a fact and the other
    /// is the app admitting it does not know, which is what it was doing before this existed,
    /// while drawing it as though it were the first.
    var relayPresence: [String: Bool] = [:]

    /// What this phone knows about whether a paired Mac can be reached right now.
    ///
    /// **Three cases and not a `Bool`**, because "not reachable" is two different facts and only
    /// one of them is about the Mac. The row used to be given a `Bool` and drew a grey dot for
    /// everything that was not true, so a Mac that was awake on the other side of the country and
    /// one that was switched off looked identical.
    enum Reachability: Equatable {
        /// On this network. Bonjour can see it, so it is up and it is addressable directly.
        case nearby
        /// Registered with the relay, so it is up and reachable from anywhere.
        case viaRelay
        /// The relay says it is not registered. Not quite "switched off": a Mac can be awake and
        /// reachable on its own network while being registered nowhere, and that Mac is one this
        /// phone cannot currently get to.
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

    /// The three facts, in the order that decides them: this network first, then the relay, then
    /// nothing.
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

    // MARK: - The active session's state

    // **Forwarders, and deliberately all of them.** Every property below is a per-Mac fact that
    // now lives on ``MacSession``: the getter reads it off the session the app is showing, and the
    // setter writes it there. They exist so that no screen had to change when the state underneath
    // it moved, which is the acceptance test for this stage — the seam is proved by being
    // invisible. Stage 5 is what removes the ones whose screens have learned to ask a particular
    // session rather than "the" session.
    //
    // The doc comments that were on these properties are on the stored ones in ``MacSession``.

    /// What the Mac calls itself, or what it was dialled as before the handshake.
    var hostName: String? {
        get { activeSession?.hostName }
        set { activeSession?.hostName = newValue }
    }

    /// The Mac's own device ID, once the handshake has said what it is.
    var currentHostID: String? {
        get { activeSession?.hostID }
        set { activeSession?.hostID = newValue }
    }

    /// Round trip of the control channel, which goes through the relay in every session.
    var latencyMilliseconds: Double? {
        get { activeSession?.latencyMilliseconds }
        set { activeSession?.latencyMilliseconds = newValue }
    }

    /// Round trip of the lane the picture is arriving on, and whether that lane is the direct one.
    var pathLatencyMilliseconds: Double? {
        get { activeSession?.pathLatencyMilliseconds }
        set { activeSession?.pathLatencyMilliseconds = newValue }
    }
    var pathLatencyIsDirect: Bool {
        get { activeSession?.pathLatencyIsDirect ?? false }
        set { activeSession?.pathLatencyIsDirect = newValue }
    }

    /// The one number the status chip shows.
    var shownLatency: Double? { activeSession?.shownLatency }

    var catalog: CaptureCatalog? {
        get { activeSession?.catalog }
        set { activeSession?.catalog = newValue }
    }

    /// This session's notes, newest last. See ``MacSession/notes``.
    var notes: [String] {
        get { activeSession?.notes ?? [] }
        set { activeSession?.notes = newValue }
    }

    var activeSessionHistoryID: UUID? {
        get { activeSession?.activeSessionHistoryID }
        set { activeSession?.activeSessionHistoryID = newValue }
    }
    var activeSessionHistoryStartedAt: Date? {
        get { activeSession?.activeSessionHistoryStartedAt }
        set { activeSession?.activeSessionHistoryStartedAt = newValue }
    }
    var activeSessionBytes: Int64 {
        get { activeSession?.activeSessionBytes ?? 0 }
        set { activeSession?.activeSessionBytes = newValue }
    }
    var lastBandwidthSampleBytes: Int64 {
        get { activeSession?.lastBandwidthSampleBytes ?? 0 }
        set { activeSession?.lastBandwidthSampleBytes = newValue }
    }
    var activeSessionLogs: [String] {
        get { activeSession?.activeSessionLogs ?? [] }
        set { activeSession?.activeSessionLogs = newValue }
    }

    var videoStatus: String {
        get { activeSession?.videoStatus ?? "No video stream" }
        set { activeSession?.videoStatus = newValue }
    }
    /// The frames per second arriving, as measured by the last two polls.
    var videoFramesPerSecond: Double {
        get { activeSession?.videoFramesPerSecond ?? 0 }
        set { activeSession?.videoFramesPerSecond = newValue }
    }
    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)? {
        get { activeSession?.lastFrameSample }
        set { activeSession?.lastFrameSample = newValue }
    }
    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming: Bool {
        get { activeSession?.isVideoStreaming ?? false }
        set { activeSession?.isVideoStreaming = newValue }
    }
    /// Which channel the picture is arriving on. `.control` means the Mac's network is not
    /// letting video through and the session has fallen back — see ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport {
        get { activeSession?.videoTransport ?? .primary }
        set { activeSession?.videoTransport = newValue }
    }

    /// Which way this session's control connection is carried. See ``MacSession/connectionPath``.
    var connectionPath: ConnectionPath? {
        get { activeSession?.connectionPath }
        set { activeSession?.connectionPath = newValue }
    }

    /// Whether the picture is being carried straight between the two ends rather than around
    /// through the relay.
    var usedDirectPath: Bool {
        get { activeSession?.usedDirectPath ?? false }
        set { activeSession?.usedDirectPath = newValue }
    }

    /// What the attempt at a path straight to the Mac has come to.
    var directPathStatus: ClientSession.DirectPath {
        get { activeSession?.directPathStatus ?? .notTried }
        set { activeSession?.directPathStatus = newValue }
    }

    /// What the relay's datagram lane carried, kept after the session ends.
    var datagramCounts: ClientSession.DatagramCounts? {
        get { activeSession?.datagramCounts }
        set { activeSession?.datagramCounts = newValue }
    }

    /// The picture the stream is showing now, or `nil` before the Mac has described one.
    var picture: PictureIdentity? {
        get { activeSession?.picture }
        set { activeSession?.picture = newValue }
    }

    /// Something the Mac wants said about the picture, or `nil`.
    var remoteNotice: NoticePayload? {
        get { activeSession?.remoteNotice }
        set { activeSession?.remoteNotice = newValue }
    }

    /// When the session that is up now came up, for the elapsed-time readout.
    var sessionStartedAt: Date? {
        get { activeSession?.sessionStartedAt }
        set { activeSession?.sessionStartedAt = newValue }
    }

    /// Which capture source this session is showing.
    var activeSourceID: String? {
        get { activeSession?.activeSourceID }
        set { activeSession?.activeSourceID = newValue }
    }

    /// Optimistic state for the current session's physical-display privacy command.
    var privacyModeEnabled: Bool {
        get { activeSession?.privacyModeEnabled ?? false }
        set { activeSession?.privacyModeEnabled = newValue }
    }
    /// The quality the app is set to, read straight from the defaults.
    ///
    /// **The rule itself is ``MacCastKit/StreamQuality/stored(in:)``**, because it is a decoding
    /// rule rather than app state and there is a test for it that runs without an app bundle. This
    /// is the name the app knows it by.
    static var storedQuality: StreamQuality { .stored() }

    /// The bitrate preset. Stored rather than computed from the defaults, because every surface
    /// showing it has to redraw when it changes and a computed property reading `UserDefaults` is
    /// a change nothing observes — see ``terminalHistory``, which is here for the same reason.
    ///
    /// Seeded at init from ``storedQuality``, and written back by ``setStreamQuality(_:)``, which
    /// is also how the Settings tab's row reaches a session: that tab cannot be opened while one
    /// is running, so it writes the preference and the next arrival picks it up here.
    var streamQuality: StreamQuality = SessionModel.storedQuality
    /// The level to come back to when the rate is taken over by hand again.
    ///
    /// Seeded from the stored preference, so that Automatic → Manual returns to the level last
    /// saved rather than to whatever the policy happens to be sitting on. `nil` when the stored
    /// value is automatic, which is right: there is no manual level to come back to, and the
    /// policy's current tier stands in — see ``setAutomaticQuality(_:)``.
    var lastManualQuality: StreamQuality? = .storedManualLevel()

    /// Writes a quality choice down, and nothing else.
    ///
    /// **The one place the preference is stored**, used by both doors into it: a live session,
    /// which also tells its Mac, and the Settings tab, which cannot reach one because that tab is
    /// unreachable while a session runs — see ``MacSession/setStreamQuality(_:)`` and
    /// ``MacSession/applyInitialQuality()``, which read this back through ``storedQuality`` on
    /// every arrival so that a change made there is not lost.
    func rememberQualityChoice(_ quality: StreamQuality) {
        streamQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: PreferenceKeys.streamQuality)
        // Remembered for ``setAutomaticQuality(_:)``: a level picked by hand is the one to return to.
        if quality.bitrateKbps != nil { lastManualQuality = quality }
    }

    // MARK: - Clipboard
    /// The most recently received host clipboard text. `nil` until the first pull.
    var hostClipboard: String? {
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

    /// The player for the Mac's audio, one per session.
    ///
    /// One object per Mac, and the rule that only the active one plays, which is Stage 5's work:
    /// two Macs' worth of sound arriving at one phone would be two things playing at once, and
    /// only one of them is the Mac the user is looking at.
    var audioPlayer: RemoteAudioPlayer? {
        get { activeSession?.audioPlayer }
        set { activeSession?.audioPlayer = newValue }
    }

    /// Whether the Mac's own audio is played here, or dropped.
    ///
    /// **On by default, and it used to be off.** What arrives on this channel is everything the
    /// Mac plays (music, a call, a video) and also every system sound it makes in response to
    /// what this phone sends it: the alert for a chord that leads nowhere, the trudge of a failed
    /// drop. Those are the Mac talking back to a command the user just gave, played into their
    /// ear a round trip later, which is why this started off.
    ///
    /// It ships on for the reason the switch exists at all: the sound is most of what makes a
    /// remote session feel like the machine rather than a picture of it, and a feature nobody
    /// knows to turn on is a feature nobody has. The alert is the exception and the switch is one
    /// tap away, in the session panel, under Stream.
    var hostAudioMuted = UserDefaults.standard.object(forKey: PreferenceKeys.hostAudioMuted) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hostAudioMuted, forKey: PreferenceKeys.hostAudioMuted)
            // Every Mac, not the one on screen: the switch is the user's answer about the Mac's
            // sound in general, and a Mac behind the one being looked at is exactly the one that
            // would keep playing unnoticed. See ``MacSession/shouldPlayAudio``.
            for session in sessions { session.refreshAudioMuteState() }
        }
    }

    /// Whether the Mac's audio comes out of this phone, which is the switch **and** the plan.
    ///
    /// Two conditions rather than one because they are two different refusals and only one of them
    /// is the user's. The switch is what somebody chose; ``StoreManager/access`` is what they
    /// bought, and the sound of the Mac is on the Relay plan and above. A gate drawn on the switch
    /// is not enough on its own: the audio keeps arriving over a connection the user already has,
    /// so a free user who never touches anything would still hear it unless the player is told.
    /// That is why this is asked in the one place the player is configured rather than only where
    /// the switch is drawn.
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

    /// Folders asked for and not yet answered — what a spinner on the panel is reading.
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

    /// What each trusted Mac is called, by the ID its pin is keyed by.
    ///
    /// The pin store knows only the ID, so the picker was listing `A1B2C3…` where the user
    /// expects the name of their Mac. The handshake is the only moment the client is told both,
    /// so it is the only moment this can be recorded.
    var hostNames: [String: String] = [:]

    /// The ID a first pairing was dialled by, while one is in flight or has just failed.
    ///
    /// Kept because the one failure this path produces on its own is the wrong ID: the relay
    /// answers for whatever holds the ID it was given, so "not registered" and "you typed one
    /// digit wrong" arrive as the same message, and the only thing that can tell the user which
    /// they are looking at is the ID they asked for. Cleared by every other connect, so it can
    /// never caption a session that was not a first pairing — see ``connect(to:)``.
    var remotePairingHostID: String?

    /// When each trusted Mac was last successfully connected to, keyed by host ID.
    var lastConnectedAt: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "hostLastConnectedAt"),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    static let hostNamesKey = "Peering.hostNames"

    /// The failure to show the user, if the session is in one.
    ///
    /// The phase carries it and the diagnostics screen has always listed it, but the picker
    /// showed nothing at all — so a connection that failed instantly looked exactly like a
    /// button that did not work, which is a worse failure than the one being reported.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// The name to show for a trusted Mac, or nil when this device has never seen that ID —
    /// a Mac paired from somewhere else, or paired before names were being kept.
    /// Names the user has chosen, which win over the name the Mac reports.
    ///
    /// Kept apart from ``hostNames`` rather than overwriting an entry in it, and that is not
    /// tidiness: `hostNames` is rewritten from the Mac's own `ServerHello` on every connect, so a
    /// rename stored there would survive exactly until the next handshake and then quietly
    /// revert. Two maps, and the user's is asked first.
    ///
    /// Worth having for anyone whose Macs are all called the same thing — three MacBook Pros
    /// arrive as "Damian's MacBook Pro" three times over, and the device ID is the only thing
    /// telling them apart.
    var customHostNames: [String: String] = [:]

    static let customHostNamesKey = "Peering.customHostNames"

    func displayName(forHostID id: String) -> String? { customHostNames[id] ?? hostNames[id] }

    /// Names a Mac, or puts its own name back if the new one is empty.
    func rename(hostID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customHostNames.removeValue(forKey: hostID)
        } else {
            customHostNames[hostID] = trimmed
        }
        UserDefaults.standard.set(customHostNames, forKey: Self.customHostNamesKey)
        publishKnownMacs()
    }

    /// Hands the widget its copy of the paired list.
    ///
    /// Pushed rather than pulled, because the widget is a separate process with no way to ask:
    /// the only moment this can be written is when the app changes something. Called from the
    /// four places that can — a pairing being established, a Mac being forgotten, a Mac
    /// reporting a new name, and a rename — which is the whole of the list.
    ///
    /// Most recently connected first, because the widget has room for a few and the Mac someone
    /// wants is almost always the one they used last.
    func publishKnownMacs() {
        let ordered = pairedHostIDs.sorted {
            (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast)
        }
        SharedStore.knownMacs = ordered.map {
            SharedStore.KnownMac(id: $0, name: displayName(forHostID: $0) ?? "A Mac")
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
    }

    /// Set when the device's own identity could not be loaded. Everything else is moot in
    /// that case: without a client certificate there is nothing for the Mac to pin.
    var identityFailure: String?

    // MARK: - User choices

    /// The address and port the manual-connect card is showing.
    ///
    /// Remembered across launches, and deliberately *not* used to reconnect to anything. This app
    /// does not dial remembered addresses — the relay path exists precisely so that it does not
    /// have to — and a stored IP is the thing that goes stale exactly when a network changes.
    ///
    /// What they are remembered for is typing. A Mac on a custom port reached by address would
    /// otherwise need the same address and the same number entered again on every launch, and
    /// that is the one case where a port other than the default costs the user anything at all.
    var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: Self.manualAddressKey) }
    }
    var manualPort: String {
        didSet { UserDefaults.standard.set(manualPort, forKey: Self.manualPortKey) }
    }

    static let manualAddressKey = "Peering.manualAddress"

    static var defaultDeviceName: String {
        // UIDevice.current.name requires Apple approval for the custom name entitlement on iOS 16+.
        // Use localizedModel ("iPhone") + model identifier as fallback to give each device a
        // recognisable-enough label until the user sets one explicitly in Settings.
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
    /// Kept as a number rather than an index so the label and the arithmetic read the same, and
    /// persisted because it is a property of the hand, not of the session — someone who has
    /// found the speed they like wants it next time.
    var pointerSpeed: Double =
        UserDefaults.standard.object(forKey: PreferenceKeys.pointerSpeed) as? Double ?? 1

    var showKeyboard = false
    var typedPreview = ""

    // MARK: - Purchase

    let storeManager = StoreManager()
    /// Why the paywall is up, or `nil` when it is not. Shows `PaywallView`.
    ///
    /// The reason travels with the flag rather than beside it, so the screen that shows the paywall
    /// never has to guess which door the user came through — and so a second door cannot be added
    /// without saying what it is. There are six now: the relay refusing a connection, the Sessions
    /// tab's relay card, a row in Settings, a locked control the user just pressed (see
    /// ``PaywallView/Reason/feature(_:)``), and the two the app opens by itself, which are
    /// ``offerSubscriptionIfDue(after:)``.
    var paywallReason: PaywallView.Reason?

    /// The plan whose allowance ran out under a live session, or `nil` when no session was cut.
    ///
    /// **The one case where a session ends and nothing on screen says why.** The relay stops
    /// splicing a connection the moment the window's allowance is spent, and it has no way to say
    /// so: what it drops is a socket, and this end sees a control connection that closed like any
    /// other. So the app does what it does about every drop (it reconnects), and the reconnect is
    /// refused with `quotaExceeded`, which is the first moment the reason exists on this side at
    /// all. See ``relaySessionDropped`` for the half of that the refusal cannot carry, and
    /// ``SessionModel/apply(_:)-swift.enum.case`` for where the two are put together.
    ///
    /// A value rather than a flag, and carrying the plan that was running when it happened, for the
    /// reason ``PaywallView/Reason/runningLow(remaining:)`` carries a figure: the sheet names the
    /// allowance the user was on, and a plan read when the sheet draws is a second source for
    /// something the sentence has already committed to.
    var spentAllowance: RelayPlan?

    /// Whether a relay session has dropped since the last time the relay refused a connection.
    ///
    /// The half of the mid-session case that the refusal cannot carry. `quotaExceeded` arrives in
    /// two situations that look identical from this side: somebody tapped Connect with the day's
    /// allowance already gone, and the relay has just cut a session that was running. They are two
    /// different things to say and only one of them is a wall the user walked into, so the
    /// difference has to be recorded before the refusal (a session was up a moment ago) and read
    /// when it arrives.
    var relaySessionDropped = false

    /// Closes the explanation, and puts the app back where a session that has ended belongs.
    ///
    /// **Closing is not enough on its own, and the reason is buried in the reconnect ladder.** A
    /// session the relay cut is torn down as a *failed reconnect*, and a failed attempt during a
    /// resume is swallowed rather than shown. That is deliberate: it is what stops a race with the
    /// teardown of the session that just ended from flashing a failure card. The cost is that the
    /// phase can be left sitting on a connecting state with nothing behind it, so dismissing this
    /// sheet without ending the session would hand the user back a card that says "Connecting"
    /// about a connection that is never going to be made.
    ///
    /// Ending it is what returns the picker. A session that is up is left alone: this sheet can
    /// only be up for one that has ended.
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
    let notifier = SessionNotifier.shared

    /// Whether the last thing Bonjour said was a failure.
    ///
    /// The browser replaces a dead one on its own, but a suspended app is not running to do it:
    /// the retry it had scheduled sits behind the app's suspension and only fires once the app
    /// is running again. Coming back to the foreground is the one moment worth restarting
    /// immediately rather than waiting that out.
    var browseFailed = false
    var identity: SelfSignedIdentity?
    var device = DeviceIdentity(id: "", name: "")
    /// The wire for the Mac the app is showing.
    ///
    /// A forwarder like the rest: the connection belongs to a session, and the app's screens
    /// ask for "the" one because there is only ever one to ask about.
    var session: ClientSession? {
        get { activeSession?.wire }
        set { activeSession?.wire = newValue }
    }

    /// The half-second poll that reads the renderer's counters.
    var videoPoll: Task<Void, Never>? {
        get { activeSession?.videoPoll }
        set { activeSession?.videoPoll = newValue }
    }

    /// The offer that is waiting for the screen change to finish. See
    /// ``SessionModel/offerSubscriptionIfDue(after:)``.
    ///
    /// A task rather than a timestamp, because what has to be cancellable is the showing and not the
    /// decision — and it doubles as the flag that stops a second session ending inside the same
    /// half-second from arming a second offer.
    var pendingOffer: Task<Void, Never>?

    /// Set by the two ways the user ends a session themselves, read and cleared by the
    /// transition that follows.
    ///
    /// A dropped link and a deliberate end reach the model as the same phase, so intent has
    /// to be carried across rather than inferred — and it is carried no further than that
    /// transition, or a leftover flag would silence the news that the next session dropped.
    var userEndedSession = false

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
    }

    // MARK: - Discovery

    func start() {
        guard identityFailure == nil else { return }
        // Anything on the Lock Screen from a previous run describes a session this process did
        // not survive, and nothing else in this launch knows it is there.
        SessionActivity.shared.adoptOrphan()
        browser.onEvent = { [weak self] event in
            // Bound once, outside the `Task`. A `weak self` reference is a mutable variable,
            // and reading it from a closure that outlives this one is a data race the compiler
            // is right to flag.
            guard let self else { return }
            // HostBrowser reports from its own queue. Every one of these touches observable
            // state, so each is hopped deliberately rather than by luck.
            Task { @MainActor in self.apply(event) }
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
    /// **Any Mac and not the one on screen.** A row that dialled a second Mac while the first was
    /// open is the case the plan gates, and a row disabled by the active session's phase alone
    /// would be enabled the moment the user looked at a Mac that had finished — which is exactly
    /// when the gate is the thing standing between them and a connection.
    var isBusy: Bool { hasOpenSession }

    func connect(to target: ClientSession.Target) {
        connect(to: target, replacing: nil)
    }

    /// Opens a Mac, replacing one session if there is one to replace.
    ///
    /// - Parameter old: the session this attempt supersedes, or `nil` when it is a Mac being
    ///   opened from the picker. A replaced session is removed rather than left to be pruned,
    ///   because its ladder has just handed over and two entries for one Mac is what a user reads
    ///   as "it connected twice".
    func connect(to target: ClientSession.Target, replacing old: MacSession?) {
        guard let identity, identityFailure == nil else { return }

        // **The gate, at the one place every route passes through.** The picker's row, the strip's
        // plus and the widget's URL all arrive here, so a gate drawn on one of them cannot be
        // walked past by another — which is the shape of gate that ends up on a review as a
        // promise the app does not keep. See ``PlanCapability/concurrentSessions``.
        //
        // A ladder putting a Mac back is deliberately not gated: that Mac is already open and the
        // plan was checked when it was, so asking again would end a session the user has paid for
        // the moment their subscription lapsed mid-reconnect.
        if old == nil, hasOpenSession, !canAddAnotherSession {
            paywallReason = .feature(.concurrentSessions)
            return
        }
        // **Said rather than silently refused.** The ceiling is a fact about this phone rather
        // than about the user's plan, and a tap that did nothing at all would read as the app
        // being broken rather than as a limit being reached.
        if old == nil, openSessions.count >= Self.sessionCeiling {
            append(note: "This phone holds \(Self.sessionCeiling) Macs open at once. Close one to open another.")
            return
        }

        // Remembered for the home-screen widget, which can offer to connect but has no way of
        // knowing to what — see ``reconnectToLastHost()``. Written twice on purpose: the app
        // reads its own defaults, and the widget can only see the shared container.
        UserDefaults.standard.set(target.displayName, forKey: Self.lastHostNameKey)
        SharedStore.lastHostName = target.displayName
        // A widget is not a live view and is not told anything. Without this it goes on showing
        // the previous Mac until the system next feels like refreshing it, which on a widget
        // that changes twice a year could be tomorrow.
        WidgetCenter.shared.reloadAllTimelines()

        // Intent does not survive into the next attempt: a flag left over from a session the
        // user ended would otherwise suppress the news that its successor has dropped.
        userEndedSession = false
        // An attempt from the backoff timer would race this one and start a second session.
        stopReconnecting()
        // And a session that is already up must be torn down rather than replaced. Assigning
        // over it leaves the first connection running with nothing holding it, so the peer sees
        // it drop mid-handshake — which reads on the Mac as a clean disconnect and, with a retry
        // following it, is a loop rather than a session.
        //
        // Let go of rather than kept: the object below replaces it in ``sessions``, and the
        // events the old connection is still emitting have nothing left to land on. That is the
        // wanted behaviour — they describe a Mac nobody is looking at any more.
        activeSession?.connectTask?.cancel()
        activeSession?.connectTask = nil
        activeSession?.wire?.disconnect()
        // The user has just asked to reach a Mac, which is the first moment the question
        // "tell you when it needs you?" means anything.
        notifier.prepareForFirstConnect()

        // **The new session, and the whole of what this stage moved.** Every per-Mac fact below
        // is set on it rather than on the model, and the screens go on reading them through the
        // forwarders because there is exactly one of these and it is the active one.
        let session = MacSession(model: self, renderer: renderer)

        // Cleared for every new session, whatever the target. A punched path belongs to the session
        // that proved it: the NAT mapping behind it can be gone by the next one, and a stale `true`
        // would have the app reporting a direct path it is not using — on the one screen somebody
        // would look at to find out why a connection is slow.
        session.usedDirectPath = false
        switch target {
        case .discovered(let host):
            session.connectionPath = .lan
            remotePairingHostID = nil
            UserDefaults.standard.set(host.id, forKey: Self.lastHostIDKey)
        case .relay(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = nil
            UserDefaults.standard.set(hostID, forKey: Self.lastHostIDKey)
        case .relayPairing(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = hostID
            // Same reasoning as the literal address below: nothing here has been proven to be
            // this Mac yet, so nothing is remembered as "the last Mac". The handshake writes
            // the ID it actually reached, and that is the first moment it is worth keeping —
            // a half-typed ID left here would be dialled again by the reconnect ladder.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        case .address:
            session.connectionPath = .direct
            remotePairingHostID = nil
            // The handshake will replace this with the server's real ID. Keeping the ID of a
            // different Mac during that window could make an automatic retry dial the relay for
            // the wrong machine.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        }
        // Fresh for the path this session just chose: the policy's tier is tuned per path, and
        // the previous session's drops are not this one's to react to.
        session.autoQualityPolicy = AutoQualityPolicy(path: session.autoQualityPath)
        session.lastAutoDroppedFrames = 0

        session.hostName = target.displayName
        // Nothing else has to be cleared: everything below this line was this connection's, and
        // this connection is new. That is the whole of what the per-Mac state bought —
        // ``disconnect()`` clears for the same reason on the way out.

        // **Bound once, outside the closure.** A `weak` reference is a mutable variable, and
        // reading it from a closure that outlives this one is a data race the compiler is right
        // to flag — and the renderer is read from the network queue, where no actor is going to
        // help. It is a `let` of a `Sendable` type, so it is reachable from there.
        let renderer = self.renderer
        let wire = ClientSession(
            identity: identity,
            clientID: device.id,
            clientName: device.name,
            pins: pins,
            onEvent: { [weak session] event in
                // **The video pipeline is the one event family that must not detour through
                // the main actor**, and for `.config` that is a correctness rule rather than
                // the performance one it is for `.frame`. At 60 Hz, hopping frames to the
                // main actor would put 60 a second behind the layout of the view trying to
                // draw them; hopping a config lets the frames overtake it.
                //
                // `ClientTransport` hands over everything it drained from one read in a
                // single synchronous loop, so a config and the keyframe that follows it
                // routinely arrive in the same batch. Send the config to the main actor and
                // the keyframe wins the race: it is enqueued against the *previous* format
                // description, and `configure` then flushes it away — the host's one
                // guaranteed-decodable frame, discarded, leaving the client black until the
                // encoder's next keyframe up to two seconds later. The renderer has its own
                // serial queue, so both calls belong here, where their order is whatever the
                // wire said it was.
                switch event {
                case .video(.frame(let frame)):
                    renderer.enqueue(frame)
                    return
                case .video(.config(let config)):
                    renderer.reset()
                    renderer.configure(config)
                default:
                    break
                }
                Task { @MainActor in session?.apply(event) }
            }
        )
        session.wire = wire
        // **The container, and this is the only place it changes.** A Mac that has finished is
        // not a Mac anybody is connected to and is let go of here; the one exception is a session
        // still being retried, which has a ladder running and a Mac on the other end of it.
        if let old { sessions.removeAll { $0 === old } }
        sessions.removeAll { !$0.isLive }
        sessions.append(session)
        activeSessionID = session.id

        // Whether a missing picture could be a network blocking video, which is a question
        // about *where* this Mac is and not one the session can answer for itself. A Mac found
        // over Bonjour is on this network, where the answer is a different problem entirely;
        // the relay and a typed-in address both cross networks nobody here controls.
        //
        // On the relay as it stands the picture already shares the control channel, so asking
        // for it there is a reduction in rate rather than a move — which is also the honest
        // response to a channel that stalled while carrying input. The move is what it becomes
        // on any path where video has a transport of its own.
        wire.videoFallbackEnabled = session.connectionPath != .lan
        session.startVideoPolling()

        let connectTask = Task { [weak session, weak wire] in
            guard let wire else { return }
            await wire.connect(to: target)
            await MainActor.run {
                guard session?.wire === wire else { return }
                session?.connectTask = nil
            }
        }
        session.connectTask = connectTask
    }

    // MARK: - Clipboard

    /// Requests the Mac's clipboard. The result arrives as ``hostClipboard`` once the host responds.
    func pullClipboard() {
        guard phase == .ready else { return }
        clipboardPulling = true
        session?.send(.requestClipboard)
    }

    /// Pushes the iPhone's current clipboard text to the Mac's pasteboard.
    func pushClipboard() {
        guard phase == .ready, let text = UIPasteboard.general.string else { return }
        session?.send(.pushClipboard(text: text))
    }

    /// Copies the most recently received host clipboard to the iPhone's pasteboard.
    func copyHostClipboard() {
        guard let text = hostClipboard else { return }
        UIPasteboard.general.string = text
    }

    // MARK: - Clipboard history

    /// Everything pulled from the Mac this device has kept, newest first.
    ///
    /// The Mac's pasteboard holds one thing, so a second Pull replaces the first — this is the
    /// only place the earlier ones exist. Held here rather than in the panel because the panel is
    /// rebuilt every time it opens.
    /// Loaded through a named function rather than inline: a stored property's initialiser
    /// cannot reference `Self`, and the alternative is spelling the key twice.
    var clipboardHistory: [ClipboardEntry] = SessionModel.loadClipboardHistory()

    static func loadClipboardHistory() -> [ClipboardEntry] {
        guard let data = UserDefaults.standard.data(forKey: clipboardHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([ClipboardEntry].self, from: data)) ?? []
    }

    /// How many pulls have been recorded, so a view can tell the list changed.
    ///
    /// The entries carry no identity to diff on and the text is arbitrary — including text that
    /// repeats, which would make two identical pulls indistinguishable.
    var clipboardHistoryCount = 0

    struct ClipboardEntry: Codable, Equatable, Identifiable {
        let id: UUID
        let text: String
        let at: Date
    }

    static let clipboardHistoryKey = "Peering.clipboardHistory"
    /// Enough to find the thing you copied a few steps ago, short of being a log of everything
    /// that has crossed this device. Each entry is a whole clipboard, and clipboards can be
    /// large — a spreadsheet range, a file's worth of text.
    static let clipboardHistoryLimit = 12

    /// Files what the Mac sent us.
    ///
    /// Written down rather than kept in memory, which is a decision worth naming: this is the
    /// user's own clipboard on their own phone, and a history that empties every time the app is
    /// relaunched is one nobody would use twice. Cleared in one tap from the list.
    func rememberClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = clipboardHistory.filter { $0.text != text }
        history.insert(ClipboardEntry(id: UUID(), text: text, at: Date()), at: 0)
        if history.count > Self.clipboardHistoryLimit {
            history.removeLast(history.count - Self.clipboardHistoryLimit)
        }
        clipboardHistory = history
        persistClipboardHistory()
    }

    func removeClipboardEntry(_ id: UUID) {
        clipboardHistory.removeAll { $0.id == id }
        persistClipboardHistory()
    }

    func clearClipboardHistory() {
        clipboardHistory = []
        persistClipboardHistory()
    }

    /// Puts a history entry on the iPhone's pasteboard, which is what tapping one does.
    func copyToPhone(_ entry: ClipboardEntry) {
        UIPasteboard.general.string = entry.text
        clipboardHistoryCount += 1
    }

    /// Sends a history entry to the Mac's clipboard, which is the other half of what a tap could
    /// sensibly do with one.
    func pushToMac(_ entry: ClipboardEntry) {
        guard phase == .ready else { return }
        session?.send(.pushClipboard(text: entry.text))
    }

    private func persistClipboardHistory() {
        clipboardHistoryCount += 1
        guard let data = try? JSONEncoder().encode(clipboardHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.clipboardHistoryKey)
    }

    // MARK: - Wake-on-LAN

    /// Sends a Wake-on-LAN magic packet for the given host ID, and says what came of it.
    ///
    /// **Said out loud, because nothing else can be.** A magic packet is a UDP broadcast that no
    /// one acknowledges: there is no answer to wait for, and the two outcomes a user can see are
    /// the Mac appearing in the list a few seconds later or not. That is indistinguishable from
    /// a row that did nothing at all, which is what this was: it sent the packet, said nothing,
    /// and left somebody tapping again. The sentence also carries the limit that matters, that
    /// a broadcast does not leave the network it was sent on, because the row is offered for
    /// Macs the relay can see and those are usually somewhere else.
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
    /// A setting rather than a constant, and the only thing in the app that can turn a feature
    /// off outright. The relay is what makes a Mac reachable from outside its own network, and
    /// it is also the one part of this system that is not the user's own two devices — so
    /// whether it is used is the user's to decide rather than a default to be discovered.
    ///
    /// Turning it off does not make anything *more* encrypted; the relay already cannot read
    /// what it carries. It makes a different promise: that the Mac's device ID and the times it
    /// is connected never reach a server at all. That is the promise the FAQ makes, and it is
    /// only keepable if this actually gates every dial — see ``connectToTrusted(hostID:)``,
    /// ``reconnectToLastHost()``, ``resumeIfNeeded()`` and ``pairWithRemoteMac(hostID:)``,
    /// which are all of them.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)` so that unset is
    /// distinguishable from off. The default is on, which is the behaviour the app had before
    /// the setting existed, and `bool(forKey:)` would report that default as `false`.
    var allowsRelay: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.allowRelay) as? Bool ?? true
    }

    static let lastHostNameKey = "Peering.lastHostName"
    static let lastHostIDKey = "Peering.lastHostID"

    static let resumeKey = "Peering.resumeWhenReachable"

    /// Set while a dropped session is being put back, so the Live Activity can say so rather
    /// than keep claiming a connection that is not there.
    ///
    /// Read off the session on screen: the card describes one Mac, and the Mac it describes is
    /// the one the user was looking at when it dropped. Every session has its own answer —
    /// see ``MacSession/isReconnecting`` for why the ladder is per Mac.
    var isReconnecting: Bool {
        get { activeSession?.isReconnecting ?? false }
        set { activeSession?.isReconnecting = newValue }
    }

    /// How long to wait before each attempt at putting a dropped session back.
    ///
    /// Spread out, because the usual cause is the Mac being asleep or the network being briefly
    /// gone, and retrying every second for a minute spends a radio and a battery on an answer
    /// that has not changed. Five attempts over about forty seconds covers a Wi-Fi roam, a
    /// display waking, and a Mac that was asleep and is not any more; past that the user is
    /// better served by the picker than by a spinner.
    static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(20),
    ]

    var reconnectTask: Task<Void, Never>? {
        get { activeSession?.reconnectTask }
        set { activeSession?.reconnectTask = newValue }
    }

    var reconnectAttempt: Int {
        get { activeSession?.reconnectAttempt ?? 0 }
        set { activeSession?.reconnectAttempt = newValue }
    }

    /// Set while ``resumeIfNeeded()`` is connecting, so a failure it causes is retried by the
    /// ladder rather than reported.
    ///
    /// Coming back to the foreground is the case this exists for, and it is a race with the
    /// teardown of the session that just ended: that drop cancelled a socket moments ago and
    /// the kernel has not finished with it, so the connect that follows is aborted before it
    /// starts. It reaches the user as "Software caused connection abort" — the operating system
    /// talking, about a condition that clears itself in well under a second. Nobody asked for
    /// this attempt, so there is nobody to tell; a second one succeeds.
    var isResuming = false

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

    /// All macros — built-in first, then custom.
    var allMacros: [Macro] { Macro.defaults + customMacros }

    // MARK: - Commands to the active Mac

    // **Forwarders, like the properties above and for the same reason.** A command belongs to a
    // session; the panels have one Mac in hand and ask the app for it. Every method here means
    // "whatever Mac is on screen", which is the only answer that exists until there can be more
    // than one — see ``activeSession``. Where a command names a terminal, the ID came from the
    // Mac that made it and is unique across Macs, which is what will let Stage 4 route it to the
    // right one rather than to the one on screen.

    /// The commands sent from this phone, newest first.
    ///
    /// **App-wide, not per Mac**, which is a decision rather than an oversight: the Mac's own
    /// shell keeps the real history, and this is the shortlist the panel offers, so a command
    /// typed on one Mac is a command the user is likely to want on the other.
    ///
    /// Stored rather than computed from the defaults, because the panel has to redraw when it
    /// changes and a computed property reading `UserDefaults` is a change nothing observes.
    var terminalHistory: [String] =
        UserDefaults.standard.stringArray(forKey: PreferenceKeys.terminalHistory) ?? []

    static let terminalHistoryLimit = 30

    /// Adds a command to the list the panel offers, and writes it down.
    ///
    /// Newest first and de-duplicated, so a command run twice moves to the top rather than
    /// appearing twice — the list is for finding the one you want, and a log of repeats makes
    /// that harder. Capped, because this is a convenience and not a history file: the Mac's own
    /// shell keeps the real one.
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

    /// Files a note against the Mac on screen. See ``MacSession/append(note:)``.
    ///
    /// With no session up there is nowhere for one to go, which is right: a note describes what a
    /// Mac did, and there is no Mac to have done it.
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
        PictureIdentity.forStream(config, activeSourceID: activeSourceID, catalog: catalog)
    }
}

extension ClientSession.Phase {
    /// Whether a live connection is still behind this phase.
    ///
    /// The three that are not are the ones where anything the session was holding has no way
    /// left to be released: a latched modifier, a pressed mouse button. Everything that cares
    /// about that asks here rather than listing the phases again.
}

extension Modifiers {
    /// Names the latched modifiers for the notes list. Symbols, not words: this is read next
    /// to the same glyphs the buttons are drawn with.
    var label: String {
        var names: [String] = []
        if contains(.command) { names.append("⌘") }
        if contains(.shift) { names.append("⇧") }
        if contains(.option) { names.append("⌥") }
        if contains(.control) { names.append("⌃") }
        return names.isEmpty ? "a modifier" : names.joined()
    }
}
