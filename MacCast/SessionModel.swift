import Foundation
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

struct RemoteTerminal: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isRunning: Bool
    var output = Data()
    /// Set while the Mac is waiting on an answer — a password, or a yes or no.
    var attention: TerminalAttentionKind?
    /// The last thing this terminal was asked to do that did not work, until it speaks again.
    var failure: String?

    /// What the tab is saying about it.
    ///
    /// One value rather than four flags read in four places, because the tab can only be one
    /// colour and the order they are weighed in is most of the design: something waiting on the
    /// user outranks something broken, which outranks a shell that has ended, which outranks one
    /// that has not said anything yet.
    var state: TerminalState {
        if let attention { return .attention(attention) }
        if let failure { return .failed(failure) }
        if !isRunning { return .stopped }
        return output.isEmpty ? .starting : .running
    }

    var visibleOutput: String {
        TerminalTextSanitizer.render(output)
    }
}

/// What a terminal's tab is saying about it. See ``RemoteTerminal/state``.
enum TerminalState: Equatable {
    /// Opened, and the Mac has not answered yet — the login shell is still coming up.
    case starting
    case running
    /// Waiting on the user: a password prompt or a confirmation.
    case attention(TerminalAttentionKind)
    /// Something asked of it did not work, or its shell ended with a status.
    case failed(String)
    /// The shell has ended. Not a failure — an exit is a thing shells do.
    case stopped
}

/// Everything the UI binds to.
///
/// One owner of the session, the identity and the renderer, so there is exactly one place
/// where a network event becomes observable state — and exactly one place to look when the
/// screen shows something that does not match what the Mac is doing.
@Observable
@MainActor
final class SessionModel {
    enum ConnectionPath: String, Sendable {
        case lan = "LAN"
        case relay = "RELAY"
        case direct = "DIRECT"
    }

    /// The same three cases in the card's spelling.
    ///
    /// Mapped rather than shared because the raw values differ on purpose: this one is shouted
    /// at a diagnostics panel, and the card's is set in a chip beside a sentence. A single enum
    /// serving both would have to be named for one of them.
    static func activityPath(_ path: ConnectionPath?) -> SessionActivityAttributes.Path? {
        switch path {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        case nil: return nil
        }
    }

    /// A preset for the picture's bitrate, or the app's own choice of one.
    ///
    /// **The raw value is a storage token and not the word on screen**, which costs a `RawValue`
    /// written out by hand and buys the setting being safe to persist. It used to be
    /// `enum StreamQuality: String` with `"Auto"`, `"Low"`, `"Med"`, `"High"`, and the chip
    /// printed `rawValue` directly — fine while nothing stored it. `@AppStorage` persists the raw
    /// value, so that spelling would have keyed a saved preference on UI copy: "Med" is an
    /// abbreviation chosen for a chip that shares a row with four other controls, and the day
    /// somebody reconsiders it, every stored preference fails to decode and silently resets to
    /// automatic. The token is `init?(rawValue:)`-decoded rather than force-read so that an
    /// unknown one is distinguishable from a real answer — the same shape, for the same reason,
    /// as ``InteractionMode``.
    enum StreamQuality: CaseIterable, Hashable, Sendable, RawRepresentable {
        typealias RawValue = String

        case auto, low, medium, high

        init?(rawValue: String) {
            switch rawValue {
            case "auto": self = .auto
            case "low": self = .low
            case "medium": self = .medium
            case "high": self = .high
            default: return nil
            }
        }

        var rawValue: String {
            switch self {
            case .auto: return "auto"
            case .low: return "low"
            case .medium: return "medium"
            case .high: return "high"
            }
        }

        /// The three rates that can be picked by hand, in order.
        ///
        /// `auto` is not the fourth rung of this ladder, it is the other answer to the same
        /// question — let the app choose the rate, or choose it yourself. ``SettingsPanel``
        /// shows it that way, as one mode and then three levels, and it asks for this list
        /// rather than spelling the three out so that adding a case here cannot leave the
        /// picker behind.
        static let manualCases: [StreamQuality] = allCases.filter { $0 != .auto }

        /// The same three numbers as ``AutoQualityPolicy/Tier``, and the same source for them:
        /// `Low` here is exactly what the host caps a stream at when the picture is on the
        /// control channel, so a preset that named a different figure would read on screen as
        /// a setting that does not take.
        var bitrateKbps: Int? {
            switch self {
            case .auto: return nil
            case .low: return VideoQualityTier.low.rawValue
            case .medium: return VideoQualityTier.medium.rawValue
            case .high: return VideoQualityTier.high.rawValue
            }
        }

        /// What the status chip prints, abbreviated for the row it sits in.
        ///
        /// This is what ``rawValue`` used to be, and it is the only reason the two were ever the
        /// same string. The chip shares its row with the path, the fit and the camera, so the
        /// names are clipped to fit it — see ``title`` and ``menuTitle`` for the roomier
        /// spellings.
        var chipTitle: String {
            switch self {
            case .auto: return "Auto"
            case .low: return "Low"
            case .medium: return "Med"
            case .high: return "High"
            }
        }

        /// The name spelled out, for somewhere with more room than the status chip.
        ///
        /// ``chipTitle`` is what the chip prints, abbreviated to "Auto" and "Med" because that
        /// chip shares a row with four other controls. A settings row has the width of the
        /// panel and no such excuse.
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }

        /// The name and what it costs, for a menu that has to say what is being given up.
        ///
        /// The figure is the whole point of it: "Low" and "Medium" mean nothing to somebody who
        /// has not already learned this app's ladder, and the choice being made is how much of
        /// the connection to spend on the picture. Shared by the status chip's menu
        /// (``RemoteScreen``) and the Settings tab, so the two cannot come to describe the same
        /// four presets differently.
        var menuTitle: String {
            switch self {
            case .auto: return "Auto, follows the network"
            case .low: return "Low, 2 Mbps"
            case .medium: return "Medium, 8 Mbps"
            case .high: return "High, 20 Mbps"
            }
        }

        /// The preset that names a given automatic tier.
        ///
        /// For handing the rate over: whatever the policy had settled on is where a manual
        /// choice should start, and the two enums share their numbers through
        /// ``bitrateKbps`` but not their cases.
        init(_ tier: AutoQualityPolicy.Tier) {
            switch tier {
            case .low: self = .low
            case .medium: self = .medium
            case .high: self = .high
            }
        }
    }

    // MARK: - Connection state

    var phase: ClientSession.Phase = .idle
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
    var hostName: String?
    var tlsDescription: String?
    var latencyMilliseconds: Double?
    var catalog: CaptureCatalog?
    var notes: [String] = []
    var sessionHistory: [ClientSessionRecord] = SessionHistoryStore.load()
    var activeSessionHistoryID: UUID?
    var activeSessionHistoryStartedAt: Date?
    var activeSessionBytes: Int64 = 0
    var lastBandwidthSampleBytes: Int64 = 0
    var activeSessionLogs: [String] = []
    var videoStatus = "No video stream"
    /// The frames per second arriving, as measured by the last two polls — see
    /// ``updateFrameRate(from:)``. Zero until there have been two samples to compare.
    var videoFramesPerSecond: Double = 0
    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)?
    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming = false
    /// Which channel the picture is arriving on. `.control` means the Mac's network is not
    /// letting video through and the session has fallen back — see ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport = .primary
    var connectionPath: ConnectionPath?

    /// Whether the picture is being carried straight between the two ends rather than around
    /// through the relay.
    ///
    /// Separate from ``connectionPath`` on purpose — the relay still splices the control connection
    /// and still meters the session, so the two are genuinely different facts and collapsing them
    /// would make the allowance meter under-count. Set from the session's own observation of what
    /// arrives, and false until it says otherwise: every session starts on the relay.
    var usedDirectPath = false

    /// What the attempt at a path straight to the Mac has come to.
    ///
    /// **The half of the same fact that ``usedDirectPath`` cannot carry.** That flag is only ever
    /// true when the direct path worked, so a session that never opened one said nothing about
    /// why. This says which of the two failures it was: the relay never told this end where the
    /// Mac is, or it did and the packets went nowhere. Those have different causes and different
    /// fixes, and until this existed nothing on either end could tell them apart.
    var directPathStatus: ClientSession.DirectPath = .notTried
    var pairedHostIDs: [String] = []
    /// The quality the app is set to, read straight from the defaults.
    ///
    /// Failable decoding on purpose: an absent or unrecognised token means "nothing has been
    /// stored yet", which is ``StreamQuality/auto`` — the behaviour the app had before the
    /// setting existed. A force-read would make a token from a future version read as a choice
    /// somebody made.
    static var storedQuality: StreamQuality {
        UserDefaults.standard.string(forKey: PreferenceKey.streamQuality)
            .flatMap(StreamQuality.init(rawValue:)) ?? .auto
    }

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
    var lastManualQuality: StreamQuality? =
        SessionModel.storedQuality.bitrateKbps == nil ? nil : SessionModel.storedQuality
    var autoQualityPolicy = AutoQualityPolicy(path: .lan)
    var lastAutoDroppedFrames = 0
    /// Optimistic state for the current session's physical-display privacy command. The host
    /// always restores brightness when the last client disconnects.
    var privacyModeEnabled = false

    // MARK: - Clipboard
    /// The most recently received host clipboard text. `nil` until the first pull.
    var hostClipboard: String?
    /// Whether a clipboard pull is in flight.
    var clipboardPulling = false

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
    var audioPlayer: RemoteAudioPlayer?

    /// Whether the Mac's own audio is played here, or dropped.
    ///
    /// Off by default, which is a decision rather than a default. What arrives on this channel is
    /// everything the Mac plays — music, a call, a video — and also every system sound it makes
    /// in response to what this phone sends it: the alert for a chord that leads nowhere, the
    /// trudge of a failed drop. Those are the Mac talking back to a command the user just gave,
    /// played into their ear a round trip later, and they are the reason this switch exists
    /// rather than a volume to turn up.
    var hostAudioMuted = UserDefaults.standard.object(forKey: PreferenceKey.hostAudioMuted) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hostAudioMuted, forKey: PreferenceKey.hostAudioMuted)
            audioPlayer?.isMuted = hostAudioMuted
        }
    }

    // MARK: - Terminals
    var terminals: [RemoteTerminal] = []
    var selectedTerminalID: UUID?

    /// The commands sent from this phone, newest first.
    ///
    /// Stored rather than computed from the defaults, because the panel has to redraw when it
    /// changes and a computed property reading `UserDefaults` is a change nothing observes.
    var terminalHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "Peering.terminalHistory") ?? []

    /// The command last sent, and when — so the shell's answer can be read against it.
    ///
    /// A PTY gives a byte stream with no marker for where one command's output starts, so the
    /// only thing that ties a message to a command is that it arrived right after one.
    var lastSentCommand: String?
    var lastSentAt: Date?

    // MARK: - File browsing

    /// Every folder the Mac has listed, keyed by the terminal it was listed for and the path it
    /// was listed at. See ``RemoteDirectoryKey``.
    ///
    /// Held rather than asked for per appearance, and that is most of what makes browsing feel like
    /// a file manager instead of a series of waits: stepping into a folder and back out of it is
    /// instant, and a folder already in hand is shown while its next copy is on the way.
    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]

    /// Which folder each terminal's browser is showing, and no entry for a browser that has not
    /// opened yet or one still waiting on the Mac's home folder to resolve to a path.
    ///
    /// In the model rather than in the panel because the panel is rebuilt every time it opens —
    /// the same reason the clipboard history is here — and because resolving "home" into a path is
    /// something only the Mac can answer.
    var browsingPaths: [UUID: String] = [:]

    /// Folders asked for and not yet answered — what a spinner on the panel is reading.
    var pendingDirectories: Set<RemoteDirectoryKey> = []

    /// Why a folder could not be listed, until it lists.
    var browseFailures: [RemoteDirectoryKey: String] = [:]

    /// The file being shown, and how much of it has arrived. One at a time because only one can be
    /// on screen — opening another replaces it.
    var filePreview: RemoteFilePreview?

    /// A command waiting for the shell that will run it.
    ///
    /// Running a file opens a terminal of its own, and a terminal has no id until the Mac answers
    /// that it made one — so the command cannot be sent when the button is tapped, only remembered
    /// until ``SessionModel/apply(terminal:)`` sees the shell arrive. One at a time, because the
    /// second tap in the moment before the first shell exists means to run the second file, not
    /// both, and a queue would be a promise about ordering that nothing here needs to make.
    var pendingRun: String?

    /// A file on its way to the Mac, and which door it came through.
    struct FileWrite: Equatable {
        /// Whether the file is an editor's text or one the user picked.
        ///
        /// The two are answered differently and are the same operation: a save reads the file back,
        /// so the editor shows what is on disk rather than what was sent; an upload asks for the
        /// folder again, so the new file appears in the list. Everything else about them (the
        /// chunking, the size cap, the refusal, the failure) is shared, which is why they share a
        /// record rather than two dictionaries that would have to be kept in step.
        enum Door { case save, upload }

        let door: Door
        /// The file being written. What the Mac's answer is matched on, since it names the file it
        /// wrote, and what says which folder to ask for again after an upload.
        let path: String
    }

    /// Files on their way to the Mac, by the terminal they are being written through.
    ///
    /// By terminal rather than one flag, because two can be in the air at once: a user who starts
    /// an upload and then switches to another shell and edits a file there has two transfers
    /// running, and a single flag hands the first answer to arrive to whichever of them asked
    /// second. The Mac keeps its own half keyed the same way, for the same reason.
    var writes: [UUID: FileWrite] = [:]

    /// Why a write did not land, by the terminal it was made through, and kept apart by door.
    ///
    /// Apart, because the two are fixed differently and say so differently: a save that failed is a
    /// file to correct, an upload that failed is a file to choose again. Read through
    /// ``saveFailure(sessionID:)`` and ``uploadFailure(sessionID:)`` so the panel asks about the
    /// terminal it is drawing rather than about whichever wrote last.
    var saveFailures: [UUID: String] = [:]
    var uploadFailures: [UUID: String] = [:]

    /// Something being made, renamed or removed on the Mac, and which folder to ask about after.
    struct FileChange: Equatable {
        /// What is being asked for. Held rather than only the path, because the answer says what
        /// happened but not what was *asked*, and the path a rename moves is built from both.
        let operation: RemoteFileOperation
        /// The path the request named — the file's own path for a rename, not the one it becomes.
        /// What the Mac's answer is matched on, since it echoes back what it was sent.
        let path: String
    }

    /// Changes in the air, by the terminal they were asked through.
    ///
    /// One per terminal, and deliberately: the Mac answers a change by naming the path it was
    /// given, so two operations through one shell would be two answers matched against one
    /// remembered request. The entry is also what disables the controls, so the second tap that
    /// would cause that cannot be made.
    var changes: [UUID: FileChange] = [:]

    /// Why a change did not happen, by the terminal it was asked through.
    ///
    /// Deliberately not in ``uploadFailures`` or ``browseFailures``, and the reason is what the
    /// panel does with each of them: a browse failure replaces the list with a full-panel state,
    /// which is right for a folder that could not be read and wrong for a rename that could not
    /// land — the user would lose the folder they are looking at, along with the row they were
    /// about to try again on. This one is drawn above the list, which stays where it is.
    var changeFailures: [UUID: String] = [:]

    /// What each trusted Mac is called, by the ID its pin is keyed by.
    ///
    /// The pin store knows only the ID, so the picker was listing `A1B2C3…` where the user
    /// expects the name of their Mac. The handshake is the only moment the client is told both,
    /// so it is the only moment this can be recorded.
    var hostNames: [String: String] = [:]
    /// The server ID of the currently (or most recently) connected Mac.
    var currentHostID: String?

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

    /// Whether this Mac is showing a name the user chose rather than the one it reports.
    func isRenamed(hostID: String) -> Bool { customHostNames[hostID] != nil }

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

    /// When the session that is up now came up, for the elapsed-time readout. `nil` whenever
    /// there is no ready session.
    ///
    /// A `Date` and not a counter: the view formats it with `Text(_:style:.timer)`, which the
    /// system advances on its own. A `Timer` here would wake the main actor once a second to
    /// update a number that the screen can already count by itself.
    var sessionStartedAt: Date?

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
        rawValue: UserDefaults.standard.string(forKey: PreferenceKey.keyboardMode) ?? "unicode"
    ) ?? .unicode
    var isObserving = false
    var latchedModifiers: Modifiers = []
    var activeSourceID: String?

    /// Something the Mac wants said about the picture, or `nil`.
    ///
    /// Kept apart from `videoStatus`, which describes the *stream*. This describes the Mac
    /// behind a perfectly healthy stream: the frames are arriving on time and every one of
    /// them is black, because the screen they are of is asleep. From the phone those two look
    /// identical, and only the Mac knows which it is.
    var remoteNotice: NoticePayload?
    /// What the joystick multiplies the pointer's travel by.
    ///
    /// Kept as a number rather than an index so the label and the arithmetic read the same, and
    /// persisted because it is a property of the hand, not of the session — someone who has
    /// found the speed they like wants it next time.
    var pointerSpeed: Double = UserDefaults.standard.object(forKey: "Peering.pointerSpeed") as? Double ?? 1

    var showKeyboard = false
    var typedPreview = ""

    // MARK: - Purchase

    let storeManager = StoreManager()
    /// Why the paywall is up, or `nil` when it is not. Shows `PaywallView`.
    ///
    /// The reason travels with the flag rather than beside it, so the screen that shows the paywall
    /// never has to guess which door the user came through — and so a second door cannot be added
    /// without saying what it is. There are five now: the relay refusing a connection, the Sessions
    /// tab's relay card, a row in Settings, and the two the app opens by itself — see
    /// ``offerSubscriptionIfDue(after:)``.
    var paywallReason: PaywallView.Reason?

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
    var session: ClientSession?
    var videoPoll: Task<Void, Never>?

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

    var isBusy: Bool { phase.holdsSession }

    func connect(to target: ClientSession.Target) {
        guard let identity, identityFailure == nil else { return }

        // Remembered for the home-screen widget, which can offer to connect but has no way of
        // knowing to what — see ``reconnectToLastHost()``. Written twice on purpose: the app
        // reads its own defaults, and the widget can only see the shared container.
        UserDefaults.standard.set(target.displayName, forKey: Self.lastHostNameKey)
        SharedStore.lastHostName = target.displayName
        // Cleared for every new session, whatever the target. A punched path belongs to the session
        // that proved it: the NAT mapping behind it can be gone by the next one, and a stale `true`
        // would have the app reporting a direct path it is not using — on the one screen somebody
        // would look at to find out why a connection is slow.
        usedDirectPath = false
        switch target {
        case .discovered(let host):
            connectionPath = .lan
            remotePairingHostID = nil
            UserDefaults.standard.set(host.id, forKey: Self.lastHostIDKey)
        case .relay(let hostID, _, _):
            connectionPath = .relay
            remotePairingHostID = nil
            UserDefaults.standard.set(hostID, forKey: Self.lastHostIDKey)
        case .relayPairing(let hostID, _, _):
            connectionPath = .relay
            remotePairingHostID = hostID
            // Same reasoning as the literal address below: nothing here has been proven to be
            // this Mac yet, so nothing is remembered as "the last Mac". The handshake writes
            // the ID it actually reached, and that is the first moment it is worth keeping —
            // a half-typed ID left here would be dialled again by the reconnect ladder.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        case .address:
            connectionPath = .direct
            remotePairingHostID = nil
            // The handshake will replace this with the server's real ID. Keeping the ID of a
            // different Mac during that window could make an automatic retry dial the relay for
            // the wrong machine.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        }
        autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath)
        lastAutoDroppedFrames = 0
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
        session?.disconnect()
        session = nil
        // The user has just asked to reach a Mac, which is the first moment the question
        // "tell you when it needs you?" means anything.
        notifier.prepareForFirstConnect()

        hostName = target.displayName
        activeSourceID = nil
        catalog = nil
        notes.removeAll()
        terminals.removeAll()
        selectedTerminalID = nil
        // The listings and the preview describe the Mac of the session that is ending — folder
        // names from one Mac shown against another would be worse than a wait.
        directories.removeAll()
        browsingPaths.removeAll()
        pendingDirectories.removeAll()
        browseFailures.removeAll()
        filePreview = nil
        // Writes in flight were this connection's, and the Mac on the other end of them is about
        // to be a different Mac or none at all. The pieces are already gone, so there is nothing to
        // resume and nothing to cancel, only the panel's state saying it is still waiting for an
        // answer that cannot come.
        writes.removeAll()
        saveFailures.removeAll()
        uploadFailures.removeAll()
        // The same reasoning for changes, and one more consequence: a change left in flight keeps
        // the controls disabled, so a browser that reconnected to the same Mac would come back with
        // its New Folder button refusing to do anything until the tab was closed and reopened.
        changes.removeAll()
        changeFailures.removeAll()
        // Cleared with the rest: a notice describes the Mac of *this* connection, and one
        // left over would caption the next session with something nobody said about it.
        remoteNotice = nil
        videoStatus = "No video stream"
        isVideoStreaming = false
        // A lane belongs to the session that chose it. Left standing, the next connection
        // would caption its first second as a fallback it has not made.
        videoTransport = .primary
        privacyModeEnabled = false

        let session = ClientSession(
            identity: identity,
            clientID: device.id,
            clientName: device.name,
            pins: pins,
            onEvent: { [weak self] event in
                guard let self else { return }
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
                //
                // Reachable from here because `renderer` is a `let` of a `Sendable` type: an
                // immutable property cannot race, so the actor boundary does not apply to
                // reading it.
                switch event {
                case .video(.frame(let frame)):
                    self.renderer.enqueue(frame)
                    return
                case .video(.config(let config)):
                    self.renderer.reset()
                    self.renderer.configure(config)
                default:
                    break
                }
                Task { @MainActor in self.apply(event) }
            }
        )
        self.session = session
        // Whether a missing picture could be a network blocking video, which is a question
        // about *where* this Mac is and not one the session can answer for itself. A Mac found
        // over Bonjour is on this network, where the answer is a different problem entirely;
        // the relay and a typed-in address both cross networks nobody here controls.
        //
        // On the relay as it stands the picture already shares the control channel, so asking
        // for it there is a reduction in rate rather than a move — which is also the honest
        // response to a channel that stalled while carrying input. The move is what it becomes
        // on any path where video has a transport of its own.
        session.videoFallbackEnabled = connectionPath != .lan
        startVideoPolling()

        Task { await session.connect(to: target) }
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

    /// Sends a Wake-on-LAN magic packet for the given host ID, using the MAC addresses it last
    /// reported. Does nothing if no MAC addresses are stored for this host.
    func wakeHost(id: String) {
        guard let macs = hostMACAddresses[id], !macs.isEmpty else { return }
        for mac in macs {
            WakeOnLAN.send(to: mac)
        }
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
        UserDefaults.standard.object(forKey: PreferenceKey.allowRelay) as? Bool ?? true
    }

    static let lastHostNameKey = "Peering.lastHostName"
    static let lastHostIDKey = "Peering.lastHostID"

    static let resumeKey = "Peering.resumeWhenReachable"

    /// Set while a dropped session is being put back, so the Live Activity can say so rather
    /// than keep claiming a connection that is not there.
    var isReconnecting = false

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

    var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0

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

    static let customMacrosKey = "Peering.customMacros"

    /// User-defined macros, persisted across launches. Shown after the built-in defaults.
    var customMacros: [Macro] = {
        guard let data = UserDefaults.standard.data(forKey: "Peering.customMacros"),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else {
            return []
        }
        return decoded
    }()

    /// All macros — built-in first, then custom.
    var allMacros: [Macro] { Macro.defaults + customMacros }

    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    var activeSourceTitle: String? {
        guard let activeSourceID,
              let descriptor = catalog?.all.first(where: { $0.id == activeSourceID })
        else { return nil }
        return descriptor.title
    }

    /// The size of the captured content in pixels, if it is known.
    ///
    /// The catalog is preferred over the video config: the catalog describes the source
    /// before any picture arrives, so the canvas can be laid out correctly while the Mac is
    /// still switching capture sources.
    var capturePixelSize: CGSize? {
        if let activeSourceID,
           let descriptor = catalog?.all.first(where: { $0.id == activeSourceID }),
           descriptor.pixelSize.width > 0, descriptor.pixelSize.height > 0 {
            return descriptor.pixelSize
        }
        let snapshot = renderer.currentSnapshot
        if snapshot.hasConfig, snapshot.pixelWidth > 0, snapshot.pixelHeight > 0 {
            return CGSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
        }
        if let first = catalog?.displays.first { return first.pixelSize }
        return nil
    }

    /// The captured content's size in the Mac's *points*, which is the space
    /// ``RemoteCommand/joystickMove(dx:dy:)`` and ``RemoteCommand/scroll(dx:dy:)`` are in.
    ///
    /// Derived by halving the pixel size, i.e. assuming a 2× backing store. That is the only
    /// figure available: the protocol carries pixels, and the point-to-pixel scale of the
    /// captured surface is not part of it. It is an estimate, and it is used only to scale a
    /// relative nudge — being wrong by a factor of two changes how fast the cursor travels,
    /// not where it lands.
    var capturePointSize: CGSize {
        guard let pixels = capturePixelSize else { return CGSize(width: 1512, height: 982) }
        return CGSize(width: pixels.width / 2, height: pixels.height / 2)
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
