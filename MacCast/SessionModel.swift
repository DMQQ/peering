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
    var attention: TerminalAttentionKind?

    var visibleOutput: String {
        TerminalTextSanitizer.render(output)
    }
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

    enum StreamQuality: String, CaseIterable, Hashable, Sendable {
        case auto   = "Auto"
        case low    = "Low"
        case medium = "Med"
        case high   = "High"

        var bitrateKbps: Int? {
            switch self {
            case .auto: return nil
            case .low: return 2_000
            case .medium: return 8_000
            case .high: return 20_000
            }
        }
    }

    // MARK: - Connection state

    var phase: ClientSession.Phase = .idle
    var hosts: [DiscoveredHost] = []
    var browseStatus = "Looking for Macs on this network…"
    var hostName: String?
    var tlsDescription: String?
    var latencyMilliseconds: Double?
    var catalog: CaptureCatalog?
    var notes: [String] = []
    var videoStatus = "No video stream"
    /// The frames per second arriving, as measured by the last two polls — see
    /// ``updateFrameRate(from:)``. Zero until there have been two samples to compare.
    var videoFramesPerSecond: Double = 0
    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)?
    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming = false
    var connectionPath: ConnectionPath?
    var pairedHostIDs: [String] = []
    var streamQuality: StreamQuality = .auto
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

    /// What each trusted Mac is called, by the ID its pin is keyed by.
    ///
    /// The pin store knows only the ID, so the picker was listing `A1B2C3…` where the user
    /// expects the name of their Mac. The handshake is the only moment the client is told both,
    /// so it is the only moment this can be recorded.
    var hostNames: [String: String] = [:]
    /// The server ID of the currently (or most recently) connected Mac.
    var currentHostID: String?

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
    var keyboardMode: KeyboardMode = .unicode
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
        switch target {
        case .discovered(let host):
            connectionPath = .lan
            UserDefaults.standard.set(host.id, forKey: Self.lastHostIDKey)
        case .relay(let hostID, _):
            connectionPath = .relay
            UserDefaults.standard.set(hostID, forKey: Self.lastHostIDKey)
        case .address:
            connectionPath = .direct
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
        // Cleared with the rest: a notice describes the Mac of *this* connection, and one
        // left over would caption the next session with something nobody said about it.
        remoteNotice = nil
        videoStatus = "No video stream"
        isVideoStreaming = false
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
    /// ``reconnectToLastHost()`` and ``resumeIfNeeded()``, which are all of them.
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
