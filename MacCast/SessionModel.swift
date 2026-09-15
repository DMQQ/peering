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
struct Macro: Identifiable, Hashable {
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
    enum ConnectionPath: String, Sendable {
        case lan = "LAN"
        case relay = "RELAY"
        case direct = "DIRECT"
    }

    enum StreamQuality: String, CaseIterable, Hashable, Sendable {
        case low    = "Low"
        case medium = "Med"
        case high   = "High"

        var bitrateKbps: Int {
            switch self {
            case .low:    return 2_000
            case .medium: return 8_000
            case .high:   return 20_000
            }
        }
    }

    // MARK: - Connection state

    private(set) var phase: ClientSession.Phase = .idle
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var browseStatus = "Looking for Macs on this network…"
    private(set) var hostName: String?
    private(set) var tlsDescription: String?
    private(set) var latencyMilliseconds: Double?
    private(set) var catalog: CaptureCatalog?
    private(set) var notes: [String] = []
    private(set) var videoStatus = "No video stream"
    /// True while the video channel is delivering frames (not ended/absent).
    private(set) var isVideoStreaming = false
    private(set) var connectionPath: ConnectionPath?
    private(set) var pairedHostIDs: [String] = []
    private(set) var streamQuality: StreamQuality = .high

    /// What each trusted Mac is called, by the ID its pin is keyed by.
    ///
    /// The pin store knows only the ID, so the picker was listing `A1B2C3…` where the user
    /// expects the name of their Mac. The handshake is the only moment the client is told both,
    /// so it is the only moment this can be recorded.
    private(set) var hostNames: [String: String] = [:]
    /// The server ID of the currently (or most recently) connected Mac.
    private(set) var currentHostID: String?

    /// When each trusted Mac was last successfully connected to, keyed by host ID.
    private(set) var lastConnectedAt: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "hostLastConnectedAt"),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    private static let hostNamesKey = "Peering.hostNames"

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
    func displayName(forHostID id: String) -> String? { hostNames[id] }

    /// When the session that is up now came up, for the elapsed-time readout. `nil` whenever
    /// there is no ready session.
    ///
    /// A `Date` and not a counter: the view formats it with `Text(_:style:.timer)`, which the
    /// system advances on its own. A `Timer` here would wake the main actor once a second to
    /// update a number that the screen can already count by itself.
    private(set) var sessionStartedAt: Date?

    /// Set when the device's own identity could not be loaded. Everything else is moot in
    /// that case: without a client certificate there is nothing for the Mac to pin.
    private(set) var identityFailure: String?

    // MARK: - User choices

    var manualAddress = "127.0.0.1"
    var manualPort = String(ProtocolInfo.defaultPort)
    private(set) var keyboardMode: KeyboardMode = .unicode
    private(set) var latchedModifiers: Modifiers = []
    private(set) var activeSourceID: String?
    var showKeyboard = false
    private(set) var typedPreview = ""

    // MARK: - Collaborators

    let renderer = VideoRenderer()

    private let pins = ClientPinStore.standard
    private let browser = HostBrowser()
    private let notifier = SessionNotifier.shared

    /// Whether the last thing Bonjour said was a failure.
    ///
    /// The browser replaces a dead one on its own, but a suspended app is not running to do it:
    /// the retry it had scheduled sits behind the app's suspension and only fires once the app
    /// is running again. Coming back to the foreground is the one moment worth restarting
    /// immediately rather than waiting that out.
    private var browseFailed = false
    private var identity: SelfSignedIdentity?
    private var device = DeviceIdentity(id: "", name: "")
    private var session: ClientSession?
    private var videoPoll: Task<Void, Never>?

    /// Set by the two ways the user ends a session themselves, read and cleared by the
    /// transition that follows.
    ///
    /// A dropped link and a deliberate end reach the model as the same phase, so intent has
    /// to be carried across rather than inferred — and it is carried no further than that
    /// transition, or a leftover flag would silence the news that the next session dropped.
    private var userEndedSession = false

    init() {
        device = DeviceIdentity.loadOrCreate(defaultName: UIDevice.current.name)
        pairedHostIDs = pins.hostIDs
        hostNames = UserDefaults.standard.dictionary(forKey: Self.hostNamesKey) as? [String: String] ?? [:]
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

    private func apply(_ event: HostBrowser.Event) {
        switch event {
        case .started:
            browseFailed = false
            browseStatus = "Looking for Macs on this network…"
        case .updated(let hosts):
            browseFailed = false
            self.hosts = hosts
            if let pending = pendingHostID, let host = hosts.first(where: { $0.id == pending }) {
                pendingHostID = nil
                connect(to: .discovered(host))
            }
            self.resumeIfNeeded()
            browseStatus = hosts.isEmpty
                ? "No Macs found yet. Make sure Peering is running on your Mac and on the same network."
                : "\(hosts.count) Mac\(hosts.count == 1 ? "" : "s") found"
        case .failed(let message):
            // Bonjour failing is silent on iOS without the local-network permission and the
            // NSBonjourServices entry, so the message is surfaced verbatim rather than
            // smoothed over — the manual address path below is the way past it.
            //
            // Shown even though the browser is already replacing itself: the retry can take half
            // a minute, and a status line that said nothing would leave the user looking at a
            // list that has quietly stopped updating.
            browseFailed = true
            browseStatus = "Browsing failed: \(message)"
        }
    }

    // MARK: - Connecting

    /// Whether a session is up or on its way up. The same question as ``Phase/holdsSession`` —
    /// asked once, answered in one place.
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
        videoStatus = "No video stream"
        isVideoStreaming = false

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

    func connectToManualAddress() {
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)) else {
            append(note: "“\(manualPort)” is not a port number.")
            return
        }
        let host = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .address(host: host, port: port))
    }

    private func apply(_ event: ClientSession.Event) {
        switch event {
        case .phase(let phase):
            // Read before the assignment. Everything said about a transition — the banner,
            // the point the stopwatch starts from — is about where the session came from,
            // not only about where it landed.
            let previous = self.phase
            self.phase = phase
            if phase == .ready { pairedHostIDs = pins.hostIDs }
            if case .failed(let message) = phase {
                videoStatus = "Stopped: \(message)"
            }
            if phase == .disconnected {
                videoStatus = "Disconnected"
            }
            if phase == .ready {
                // Restarted on every fresh arrival rather than only the first: a reconnect
                // emits `.ready` again, and elapsed time that kept counting through it would
                // be describing a session that no longer exists.
                if previous != .ready {
                    reconnectAttempt = 0
                    sessionStartedAt = Date()
                    UserDefaults.standard.set(true, forKey: Self.resumeKey)
                    // Record the last-connected timestamp for the Trusted Macs list.
                    if let id = currentHostID {
                        lastConnectedAt[id] = Date()
                        if let data = try? JSONEncoder().encode(lastConnectedAt) {
                            UserDefaults.standard.set(data, forKey: "hostLastConnectedAt")
                        }
                    }
                }
            } else {
                sessionStartedAt = nil
            }

            let userEnded = userEndedSession
            userEndedSession = false
            notifier.sessionMoved(
                from: previous,
                to: phase,
                hostName: hostName ?? "the Mac",
                deliberate: userEnded
            )
            // The same transition, said twice: once as something that can interrupt the user
            // from another app, and once as something they will see without unlocking. Neither
            // is a substitute for the other, and both read from this one place.
            // A session that ended without the user asking is put back on its own. The flag
            // inside `scheduleReconnect` is what decides whether this was theirs — the phase
            // alone cannot tell a drop from a disconnect.
            //
            // Before the activity is told, not after: scheduling is what sets `isReconnecting`,
            // and the card has to go up saying "reconnecting" rather than be taken down and
            // brought back a moment later as though nothing had happened.
            if !phase.holdsSession, !userEnded {
                scheduleReconnect()
            }
            SessionActivity.shared.sessionMoved(
                from: previous,
                to: phase,
                hostName: hostName ?? "the Mac",
                startedAt: sessionStartedAt,
                reconnecting: isReconnecting
            )

            if !phase.holdsSession {
                // The buttons stop claiming a modifier the moment the link that carried it is
                // gone. Nothing else can: the release would have to travel back over the same
                // connection. Observed on this Mac, the window server keeps the flag until a
                // real key-up arrives, so the Mac may still be holding it — which is why this
                // says so rather than quietly showing the buttons as released.
                if !latchedModifiers.isEmpty {
                    append(note: "The connection ended while \(latchedModifiers.label) was held on the Mac. It may still be held there.")
                }
                latchedModifiers = []
            }
        case .host(let hello):
            // The host's own name is authoritative. Bonjour is only a hint about where to
            // find it, and it can be stale by minutes.
            hostName = hello.hostName
            currentHostID = hello.serverID
            UserDefaults.standard.set(hello.serverID, forKey: Self.lastHostIDKey)
            if hostNames[hello.serverID] != hello.hostName {
                hostNames[hello.serverID] = hello.hostName
                UserDefaults.standard.set(hostNames, forKey: Self.hostNamesKey)
            }
        case .catalog(let catalog):
            self.catalog = catalog
            if activeSourceID == nil, let first = catalog.displays.first ?? catalog.all.first {
                activeSourceID = first.id
            }
        case .video(let event):
            apply(video: event)
        case .latency(let milliseconds):
            latencyMilliseconds = milliseconds
        case .note(let message):
            append(note: message)
        }
    }

    private func apply(video event: ClientSession.VideoEvent) {
        switch event {
        case .connecting:
            videoStatus = "Opening the video channel…"
            isVideoStreaming = false
        case .config(let config):
            // The decoder half of this is done on the network queue, in the same place the
            // frames are handled, so that it is ordered against them — see the event handler
            // in `connect(to:)`. Flushing and reconfiguring here instead would put the reset
            // *after* a keyframe that arrived in the same read, and throw that keyframe away.
            // Only the labels belong on the main actor.
            videoStatus = "\(config.codec.rawValue.uppercased()) \(config.pixelWidth)×\(config.pixelHeight)"
            isVideoStreaming = true
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
        case .ended(let reason):
            videoStatus = "Video ended: \(reason)"
            isVideoStreaming = false
        }
    }

    private func startVideoPolling() {
        videoPoll?.cancel()
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let snapshot = self.renderer.currentSnapshot
                if snapshot.hasConfig {
                    let suffix = snapshot.framesDropped > 0 ? " · \(snapshot.framesDropped) dropped" : ""
                    let waiting = snapshot.awaitingKeyframe ? " · waiting for a keyframe" : ""
                    self.videoStatus = "\(snapshot.codec.rawValue.uppercased()) \(snapshot.pixelWidth)×\(snapshot.pixelHeight) · \(snapshot.framesEnqueued) frames\(suffix)\(waiting)"
                }
            }
        }
    }

    private func append(note: String) {
        notes.append(note)
        if notes.count > 12 { notes.removeFirst(notes.count - 12) }
    }

    // MARK: - Pairing

    func confirmPairing(accepted: Bool) {
        // Declining ends the session from the Mac's side too, and that arrives as a
        // `.disconnected` like any other — with the model's phase still on `.confirming`.
        // Without this the user's own "no" comes back to them as a lost connection.
        if !accepted { userEndedSession = true }
        session?.confirmPairing(accepted: accepted)
    }

    /// Ends the session now.
    ///
    /// `deliberate` answers "did the user mean to do this", which is not the same question as
    /// "who called this function". A disconnect the user tapped is silent; one iOS forced
    /// because it is about to suspend the app is not, because they are looking at something else
    /// and a banner is the only way they will ever hear about it.
    func disconnect(deliberate: Bool = true) {
        // Recorded before anything moves. `ClientSession` announces the end itself, and by
        // the time that event is applied the phase below has already been set — so this flag
        // is the only evidence left that the user, and not the network, ended it.
        userEndedSession = deliberate
        // Only a deliberate one. A drop, and the end iOS forces on a backgrounded app, are the
        // two cases where coming back to the app should find the session restored.
        if deliberate {
            UserDefaults.standard.set(false, forKey: Self.resumeKey)
            stopReconnecting()
        }
        sessionStartedAt = nil
        session?.disconnect()
        session = nil
        videoPoll?.cancel()
        videoPoll = nil
        renderer.reset()
        connectionPath = nil
        latchedModifiers = []
        phase = .disconnected
    }

    /// A trusted Mac the user asked for, waiting on discovery to produce it.
    ///
    /// Kept for an in-flight Bonjour update from an older request. New requests no longer need
    /// to wait: they use the relay immediately when the Mac is not visible on the LAN.
    private var pendingHostID: String?

    /// Whether a trusted Mac has been asked for and not yet found.
    var isWaitingForHost: Bool { pendingHostID != nil }

    /// Connects to a Mac this device has paired with before, by ID.
    ///
    /// Bonjour wins when it has the Mac, preserving the existing direct LAN path. Otherwise the
    /// same stable host ID is sent to the relay; no remembered IP address is involved.
    func connectToTrusted(hostID: String) {
        if let host = hosts.first(where: { $0.id == hostID }) {
            pendingHostID = nil
            connect(to: .discovered(host))
            return
        }
        pendingHostID = nil
        connect(to: .relay(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    // MARK: - Quick connect

    /// Where the name of the last Mac this device connected to is kept.
    ///
    /// In `UserDefaults` rather than in the app group the widget would need to read it, because
    /// the widget does not need to know *which* Mac — it offers to connect, and the app decides
    /// to what. That keeps a shared container, its entitlement and its provisioning out of a
    /// feature whose whole job is to save one tap.
    private static let lastHostNameKey = "Peering.lastHostName"
    private static let lastHostIDKey = "Peering.lastHostID"

    /// Reconnects to the Mac this device used last. A matching Bonjour result uses the direct
    /// LAN path; a trusted ID that is not currently visible uses the relay.
    func reconnectToLastHost() {
        guard !phase.holdsSession else { return }
        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            connect(to: .discovered(host))
        } else if let hostID, pins.hostIDs.contains(hostID) {
            connect(to: .relay(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac"))
        }
    }

    /// Whether the next sight of the last Mac should put the session back.
    ///
    /// Written down rather than remembered, because the case that matters most is the one where
    /// iOS killed the app while it was backgrounded: nothing of the session survives that, and
    /// "there was one" has to have been recorded before it happened.
    private static let resumeKey = "Peering.resumeWhenReachable"

    /// Set while a dropped session is being put back, so the Live Activity can say so rather
    /// than keep claiming a connection that is not there.
    private(set) var isReconnecting = false

    /// How long to wait before each attempt at putting a dropped session back.
    ///
    /// Spread out, because the usual cause is the Mac being asleep or the network being briefly
    /// gone, and retrying every second for a minute spends a radio and a battery on an answer
    /// that has not changed. Five attempts over about forty seconds covers a Wi-Fi roam, a
    /// display waking, and a Mac that was asleep and is not any more; past that the user is
    /// better served by the picker than by a spinner.
    private static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(20),
    ]

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    /// Puts the session back, if there was one and the user did not end it.
    ///
    /// Called from three places because they cover different arrivals. Coming back to the front
    /// is the short trip — the app is still in memory and the Mac is already in the browser's
    /// list. A host appearing is the cold launch, where the browser has only just started and
    /// the Mac is not in a list that has not been filled in yet. And a timer is the drop that
    /// happens while the user is looking at the screen, which is the case they notice.
    ///
    /// A deliberate disconnect clears the flag and nothing here fires; a dropped connection
    /// leaves it set, which is exactly the case this exists for.
    private func resumeIfNeeded() {
        // `session` is assigned synchronously in ``connect(to:)``, before the phase has heard
        // anything, while the browser fires `updated` on its own schedule — so the session is
        // the only reliable evidence that an attempt is already in flight. Without it the retry
        // and the browser can both start one, and each silently closes the other's connection.
        guard session == nil, !phase.holdsSession else {
            stopReconnecting()
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.resumeKey) else { return }

        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            stopReconnecting()
            connect(to: .discovered(host))
        } else if let hostID, pins.hostIDs.contains(hostID) {
            stopReconnecting()
            connect(to: .relay(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac"))
        } else {
            scheduleReconnect()
        }
    }

    /// Arms the next attempt, if there is one left to make.
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        guard reconnectAttempt < Self.reconnectDelays.count else {
            isReconnecting = false
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.resumeIfNeeded()
        }
    }

    /// Stops the retry, *without* resetting the backoff.
    ///
    /// The counter belongs to a run of attempts, and resetting it here is what turned a failing
    /// reconnect into a permanent loop: every cycle called this, so the attempt count returned to
    /// zero and the delays never advanced past the first second. Only a session that actually
    /// came up clears it — see the `.ready` branch in ``apply(_:)``.
    private func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    // MARK: - Backgrounding

    /// The reprieve iOS grants a backgrounded app, and what happens when it runs out.
    ///
    /// There is no background mode a remote desktop can honestly claim — the app is not playing
    /// audio, tracking a location or servicing a call — so this is the whole of it. It is not a
    /// fix for the session ending when the app is backgrounded, and cannot be: it buys the few
    /// seconds that make switching to another app for something and coming straight back
    /// survivable, and nothing beyond that.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Called when the app is backgrounded with a session up.
    func enteringBackground() {
        SessionActivity.shared.enteringBackground()
        guard phase.holdsSession, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Peering session") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        SessionActivity.shared.returningToForeground()
        endBackgroundAssertion()
        // A browse that died while the app was in the background has been sitting behind its own
        // backoff in a suspended process. Starting one now is the difference between a list that
        // is there when the user looks and one that fills in several seconds later.
        if browseFailed { restartBrowsing() }
        resumeIfNeeded()
    }

    /// Ends the session when the background window runs out, rather than letting the system
    /// kill it.
    ///
    /// The difference is visible in two places. The Live Activity is taken down and the Mac is
    /// told the session is over, instead of a Lock Screen card sitting there claiming a
    /// connection that ended — which it cannot correct, because nothing of ours is running to
    /// correct it with. And the user, who is not looking, gets a banner.
    private func backgroundTimeExpired() {
        endBackgroundAssertion()
        guard phase.holdsSession else { return }
        disconnect(deliberate: false)
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Forgets the pin for a Mac. The Mac keeps its half, so the next connection is refused
    /// by it until it is unpaired on that side too — which is the honest behaviour for
    /// "forget", as opposed to a silent re-pair.
    func forget(hostID: String) {
        pins.remove(hostID: hostID)
        pairedHostIDs = pins.hostIDs
        append(note: "Forgot \(hostID). Unpair this device on the Mac as well.")
    }

    /// Destroys this device's identity key and mints a fresh one under a new device ID.
    ///
    /// Both, not just the key. A Mac that already holds a pin for this client ID will only
    /// ever accept the key it pinned, so rotating the key alone locks the device out of every
    /// Mac it has paired with. Changing the ID as well makes this device a stranger again,
    /// which is what "start over" has to mean.
    func resetDeviceIdentity() {
        session?.disconnect()
        session = nil
        // The phase moves off `.ready` here rather than through `apply(_:)`, so the elapsed
        // time has to be cleared here too or the readout would outlive its session.
        sessionStartedAt = nil
        phase = .disconnected
        do {
            try SelfSignedIdentity.destroy(role: .client)
        } catch {
            append(note: "Could not destroy the old key: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return
        }
        _ = pins.removeAll()

        UserDefaults.standard.removeObject(forKey: "Peering.deviceID")
        device = DeviceIdentity.loadOrCreate(defaultName: UIDevice.current.name)

        do {
            self.identity = try SelfSignedIdentity.loadOrCreate(role: .client, commonName: device.name)
            append(note: "New identity \(device.id.prefix(8))… — pair again on the Mac.")
        } catch {
            identityFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    var thisDeviceDescription: String { "\(device.name) · \(device.id)" }

    // MARK: - Input

    /// The only path input takes. Everything goes through the session's coalescer, so the
    /// rules about what may be merged and what must never be dropped live in one place
    /// instead of in each gesture recogniser.
    func send(_ command: RemoteCommand) {
        session?.send(command)
    }

    func selectSource(_ descriptor: CaptureSourceDescriptor) {
        activeSourceID = descriptor.id
        session?.selectCaptureSource(descriptor.source)
    }

    /// The same, for a caller holding a ``CaptureSource`` rather than the descriptor it was
    /// listed under.
    ///
    /// **Recording the choice is the whole point of this existing.** `activeSourceID` is what
    /// callers compare against before deciding whether a switch is needed, so a caller that
    /// sends `setCaptureSource` itself leaves the record describing a screen the video is no
    /// longer on — and the next comparison then reads as "already there" and sends nothing.
    /// The visible result is a session that will follow the desktops panel onto the second
    /// display and then refuse to come back.
    func selectSource(_ source: CaptureSource) {
        activeSourceID = source.stableID
        session?.selectCaptureSource(source)
    }

    func launchApplication(_ descriptor: InstalledApplicationDescriptor) {
        send(.launchApplication(bundleIdentifier: descriptor.bundleIdentifier))
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        keyboardMode = mode
    }

    /// Latches a modifier on or off.
    ///
    /// Sent as a real modifier key press rather than as flag bits on the next keystroke,
    /// because that is what the host tracks: setting `flags` describes one event and does not
    /// release the modifier, so the window server would go on believing it is held. A latched
    /// modifier is also what makes a two-finger shortcut possible from a touch screen at all —
    /// there is no way to hold ⌘ with one hand and type with the other on a phone.
    func toggleModifier(_ bit: Modifiers, keyCode: UInt16) {
        let isOn = latchedModifiers.contains(bit)
        if isOn {
            latchedModifiers.remove(bit)
            send(.keyUp(keyCode: keyCode, modifiers: []))
        } else {
            latchedModifiers.insert(bit)
            send(.keyDown(keyCode: keyCode, modifiers: []))
        }
    }

    func run(_ macro: Macro) {
        // Down then up, in that order, and never coalesced — a macro whose release was
        // dropped would leave the Mac holding a modifier with no way to clear it from here.
        send(.keyDown(keyCode: macro.keyCode, modifiers: macro.modifiers))
        send(.keyUp(keyCode: macro.keyCode, modifiers: macro.modifiers))
    }

    /// Return, and the typed preview goes with it.
    ///
    /// The preview is the line the Mac has been sent since it was last emptied, and a Return is
    /// the point at which that stops describing anything: the line is committed, the field it went
    /// into has moved on, and a bar still showing the old text claims the Mac is holding something
    /// it has already taken.
    func pressReturn() {
        typedPreview = ""
        send(.keyDown(keyCode: 36, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 36, modifiers: latchedModifiers))
    }

    /// Text from the software keyboard, routed by the current mode.
    func handleTypedText(_ text: String) {
        guard !text.isEmpty else { return }
        // A newline is a Return by another name — the software keyboard delivers it as text
        // rather than as a key — so it commits the line for the same reason ``pressReturn()``
        // does, and the preview restarts from empty.
        typedPreview = text.contains(where: \.isNewline)
            ? ""
            : String((typedPreview + text).suffix(40))

        switch keyboardMode {
        case .unicode:
            send(.textInput(text))

        case .keycode:
            // Per character, with the latched modifiers attached, so ⌘-latched typing works.
            // A character with no Mac keycode — an emoji, a CJK glyph — falls back to a text
            // injection rather than being silently swallowed: losing it would be worse than
            // sending it by the other mode.
            for character in text {
                guard let code = KeycodeMap.macOSKeycode(forCharacter: character) else {
                    send(.textInput(String(character)))
                    continue
                }
                // Uppercase and the shifted symbols are the same key as their unshifted
                // forms, so shift has to ride along or "Hello" arrives as "hello".
                var modifiers = latchedModifiers
                if KeycodeMap.characterNeedsShift(character) { modifiers.insert(.shift) }
                send(.keyDown(keyCode: code, modifiers: modifiers))
                send(.keyUp(keyCode: code, modifiers: modifiers))
            }
        }
    }

    func setStreamQuality(_ quality: StreamQuality) {
        streamQuality = quality
        send(.setStreamQuality(fps: 0, bitrateKbps: quality.bitrateKbps))
    }

    func handleBackspace() {
        typedPreview = String(typedPreview.dropLast())
        // 51 is Delete (backspace) on every Mac layout. Sent in both modes: in keycode mode it
        // is a real key press, and in Unicode mode there is no text to delete backwards over,
        // so a keycode is the only thing that can express it.
        send(.keyDown(keyCode: 51, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 51, modifiers: latchedModifiers))
    }

    /// A key from a hardware keyboard, in keycode mode.
    func handleHardwareKey(_ usage: UIKeyboardHIDUsage, down: Bool, flags: UIKeyModifierFlags) {
        guard keyboardMode == .keycode,
              let code = KeycodeMap.macOSKeycode(for: usage)
        else { return }
        let modifiers = KeycodeMap.modifiers(from: flags)
        send(down ? .keyDown(keyCode: code, modifiers: modifiers)
                  : .keyUp(keyCode: code, modifiers: modifiers))
    }

    // MARK: - Geometry

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

private extension ClientSession.Phase {
    /// Whether a live connection is still behind this phase.
    ///
    /// The three that are not are the ones where anything the session was holding has no way
    /// left to be released: a latched modifier, a pressed mouse button. Everything that cares
    /// about that asks here rather than listing the phases again.
}

private extension Modifiers {
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
