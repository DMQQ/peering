import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

/// Host diagnostics, visible with:
/// `log stream --predicate 'subsystem == "pl.dmq.peering.host"'`
///
/// The window is not always reachable and every failure mode in this app is silent by nature, so
/// the unified log is where "the client connected but nothing happened" is answerable.
private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Main-actor state for the host window.
///
/// The networking layer knows nothing about SwiftUI and emits ``HostEvent`` values from a
/// background queue; this type is the single place those cross back to the main actor, so the
/// session state machine never has to reason about actor isolation.
@MainActor
@Observable
final class HostModel {
    enum Status: Equatable {
        case idle
        case starting
        case listening(port: UInt16)
        case failed(String)

        var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    private(set) var status: Status = .idle {
        didSet { publishHostWidgetState() }
    }
    private(set) var deviceName = "" {
        didSet { publishHostWidgetState() }
    }
    private(set) var deviceID = ""

    /// Present only while a first-time pairing is waiting on the user's comparison.
    private(set) var pairing: PairingPrompt?
    private(set) var lastOutcome: PairingOutcome?

    private(set) var connectedClients: [ConnectedClient] = [] {
        didSet { publishHostWidgetState() }
    }
    private(set) var pairedClientIDs: [String] = []

    // Held while at least one client is connected, released when the last one disconnects: the
    // display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    var sleepAssertionID: IOPMAssertionID = 0

    // The assertion that keeps the Mac up on its own, with no permission prompt. It is not the
    // lid-close switch, whatever the name says: `PreventSystemSleep` is what `caffeinate -s` takes,
    // and macOS reads a closed lid on a different path. See ``setKeepRunningWithLidClosed(_:)``.
    var lidSleepAssertionID: IOPMAssertionID = 0
    var preferenceDisplaySleepAssertionID: IOPMAssertionID = 0
    var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// Whether the user wants this Mac to stay up with its lid shut.
    ///
    /// The intention, not the reading. What the machine is doing is `SleepDisabled` in `pmset -g`,
    /// and the two disagree after a crash, which ``adoptLidCloseSleepSetting()`` repairs.
    var keepRunningWithLidClosed =
        UserDefaults.standard.bool(forKey: HostModel.keepRunningWithLidClosedKey)

    /// Whether `/etc/sudoers.d/peering-sleep` is doing its job, as `sudo` reports it.
    ///
    /// Nil until it has been asked, and nil again when `sudo` will not list at all, which the row
    /// treats as not knowing rather than as not installed: the two lead to different advice.
    var lidCloseRuleInstalled: Bool?

    /// Whether an administrator prompt or a process is in flight for that row.
    ///
    /// The switch cannot move until the person at the password dialog has answered, and a control
    /// that ignores a click reads as broken, so the row draws this instead.
    var lidCloseBusy = false

    /// What went wrong the last time that row was used, until the next attempt.
    var lidCloseFailure: String?

    /// What `pmset -g` last said, or `nil` before it has been read.
    ///
    /// Kept apart from ``keepRunningWithLidClosed``, which is what the user asked for. The two come
    /// apart after a crash, a force quit, a hand edit of `/etc/sudoers.d` or somebody else's
    /// `pmset`, and the row reads both so "switched on and not in force" can be said out loud.
    var lidCloseSystemState: LidCloseSleep.SleepDisabledState?

    /// The one thing this app does before a window exists.
    ///
    /// The lid-close check is here rather than in ``start()``, which runs when the window opens,
    /// because the Mac this matters on is the one nobody is looking at: set to open at login, left
    /// in a corner with its window closed. The launch after a crash is exactly that launch.
    init() {
        Task { await adoptLidCloseSleepSetting() }
        startResourceSampling()
    }

    /// Whether a given trusted device is attached right now.
    ///
    /// Matched on the ID, the only thing the two lists have in common. The name is the client's to
    /// choose and two devices can present the same one, so comparing a name against a list of IDs
    /// is a question that is always false.
    func isConnected(_ id: String) -> Bool {
        connectedClients.contains { $0.id == id }
    }
    /// Everything the host has said, newest last.
    ///
    /// Entries rather than formatted lines, so the window can show when each thing happened and
    /// which of them went wrong.
    private(set) var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Driven from two places at once, which is why it is `@unchecked Sendable` with its own lock
    /// rather than main-actor state: commands arrive on the network queue (see the `onCommand`
    /// wiring in ``start()``), the input transform is written from wherever the coordinator reports
    /// one, and the teardown release runs on the main actor. Hopping either to the other would put
    /// pointer events behind SwiftUI or the UI behind a command queue.
    private let input = InputInjector()

    /// Physical display brightness is separate from the captured pixels, which is what lets the
    /// phone keep seeing a Mac whose local panels are dark.
    private let displayPrivacy = DisplayPrivacyController()

    /// The other half of the same feature: a black cover over every display the brightness pass
    /// above will not touch, which is the whole of what a third-party monitor gets.
    private let privacyCurtain = DisplayPrivacyCurtain()

    /// Set while Privacy Mode is on, so a display attached mid-session gets covered too.
    private var displayObserver: NSObjectProtocol?
    private(set) var privacyModeEnabled = false

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed: a
    /// rejected switch means the client and the host disagree about what is on screen, and the
    /// window is the only place that disagreement can be seen.
    var pendingCaptureSource: CaptureSource?

    /// What is actually being streamed, once a switch has been applied.
    ///
    /// ``pendingCaptureSource`` above is the ask rather than the answer, cleared on success and
    /// left set on failure, which makes it useful for spotting a disagreement and useless for
    /// saying what is on screen.
    private(set) var capturingSource: CaptureSource?

    /// The last catalogue the resolver built, kept so a source can be named rather than shown as a
    /// number: a ``CaptureSource`` is a display ID or a pid, and "DELL P2212H" is what a person
    /// recognizes.
    private(set) var catalog: CaptureCatalog?

    /// The display name of what is being captured, if the catalogue can name it.
    var capturingSourceTitle: String? {
        guard let capturingSource, let catalog else { return nil }
        return catalog.all.first { $0.source == capturingSource }?.title
    }

    /// Everything this app has put on the network since it started, picture and sound.
    ///
    /// A counter rather than a rate: the subtraction that makes a rate is `ResourceMeter`'s, where
    /// it is tested. `nil` before there is a coordinator at all, which is a different answer from a
    /// coordinator that has sent nothing: the first is "this app is not hosting yet", the second is
    /// a zero the panel can print.
    var streamedBytes: UInt64? {
        guard let stats = coordinator?.streamStatistics else { return nil }
        // Counted separately because they are different kinds of traffic, added here because a user
        // asking what this app sends means the total. Widened on the way out: the streamer counts
        // in `Int`, and a byte count that has reached the panel is one with a sign it does not want.
        return UInt64(max(0, stats.bytesSent + stats.audioBytesSent))
    }

    /// What this app is costing the Mac, for the menu's readings.
    ///
    /// On the model rather than the window, because the menu is where these are read now and a menu
    /// bar app usually runs with its window closed. Sampled on a timer from launch because a rate is
    /// a difference between two readings: sampling when the menu opens would show nothing the first
    /// time and the whole interval since somebody last looked on the second.
    var resources = HostResourceSampler()

    /// Keeps ``resources`` current. Started once and never stopped: an app that is not hosting is
    /// still an app somebody may open the menu to ask about, and "nothing measurable" is a real
    /// answer that a blank row is not.
    private func startResourceSampling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                resources.sample(bytesSent: streamedBytes ?? 0)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The last name each device gave when it connected.
    ///
    /// A pin is a public key and carries no name, and the name arrives with a connection and goes
    /// when it ends, so without keeping it the device list can only offer an ID for anything not
    /// attached right now. Persisted, because the case this is for is the device that is *not* here.
    private(set) var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    private static let clientNamesKey = "Peering.clientNames"

    /// What to call a device: its own name if it has ever said one, otherwise its ID.
    func displayName(for clientID: String) -> String {
        clientNames[clientID] ?? clientID
    }

    /// A still of what is being streamed, for the window's preview.
    ///
    /// `nil` when nothing is being captured: the honest answer rather than the last picture taken,
    /// since a window still showing a frame from ten minutes ago would claim the phone can see
    /// something it cannot. The caller decides how often to ask, because the caller is the view.
    func snapshot(maxWidth: Int = 640) async -> CGImage? {
        await coordinator?.snapshot(maxWidth: maxWidth)
    }

    /// Capture, encode and send. Deliberately not main-actor bound. Nil until the first client opens
    /// a video connection, because building one touches the capture catalogue, which needs Screen
    /// Recording permission.
    /// Written only from ``start()`` and ``stop()``; every other `HostModel+*.swift` file only
    /// reads it.
    private(set) var coordinator: VideoCoordinator?

    /// Runs while at least one client is attached. See ``HostModel/startScreenWatch()``.
    var screenWatchTask: Task<Void, Never>?

    /// The capture problem the attached clients have already been told about.
    ///
    /// Held so the same one is not announced twice: a denied Screen Recording grant fails again on
    /// every attempt to start a stream, and a phone told the same thing four times ignores it.
    var announcedCaptureProblem: String?

    /// Written only from ``start()`` and ``stop()``; ``HostModel+Sessions.swift`` only reads it.
    private(set) var server: HostServer?
    private var relayRegistration: RelayHostRegistration?

    /// What the test button in Settings last had to say, shown beside it.
    ///
    /// Only half the answer to "does this work at all": a registered token means a phone handed one
    /// over while a session was up, and whether the relay then reached APNs is not visible from this
    /// Mac at any price, since the relay holds the key and answers nothing.
    private(set) var pushTestResult: String?

    /// Sends the same banner the terminal attention path sends, on purpose.
    @discardableResult
    func sendTestPush() -> String {
        // `registeredPushTokens` and not `allPushTokens`: the second leaves out every connected
        // phone, because a terminal needing attention is told to a connected phone over the session
        // rather than pushed, so asking it here answers "no device" whenever the person pressing the
        // button has the phone in their hand.
        let tokens = server?.registeredPushTokens() ?? []
        guard !tokens.isEmpty else {
            let message = "No device has registered a token with this Mac. Connect the phone once with this build installed."
            pushTestResult = message
            record(message, level: .warning)
            return message
        }

        for token in tokens {
            relayRegistration?.notifyDevice(
                token: token,
                title: "Terminal needs you",
                body: "A test notification from your Mac."
            )
        }

        let connected = server?.connectedPushClientCount() ?? 0
        let message = connected > 0
            ? "Sent to \(tokens.count) device\(tokens.count == 1 ? "" : "s"), \(connected) of them connected."
            : "Sent to \(tokens.count) device\(tokens.count == 1 ? "" : "s")."
        pushTestResult = message
        record(message)
        return message
    }
    private var nativeTerminalWatcher: NativeTerminalWatcher?
    private var pins: PinStore?
    private var identity: SelfSignedIdentity?
    private var spaceObserver: NSObjectProtocol?

    /// A visible tail of what has happened. Bounded because this is a status window, not a log
    /// viewer, and an unbounded array in `@Observable` state re-renders forever.
    private static let maxEvents = 60

    /// What the host is configured to listen on, whether or not it currently is. See
    /// ``HostModel+Port.swift``.
    var port: UInt16 = HostModel.storedPort()

    /// Everything that has to happen on the way out, including the half of the lid-close switch
    /// that makes it safe to have.
    ///
    /// `pmset -a disablesleep 1` is a machine setting and outlives this process, so a Mac whose
    /// owner turned it on and quit the app would never sleep again with nothing on screen to say
    /// why. The restore runs only when this app set it, so a machine disabled by something else is
    /// left as it was found; see ``sleepDisabledByThisAppKey``.
    ///
    /// Synchronous, and it stays that way: the process is going away, so there is no later in which
    /// to finish an `await`.
    func prepareForTermination() {
        virtualDisplayTeardownDepth += 1
        publishHostWidgetState(listening: false)
        // First, because it is the one thing here that changes the user's Mac in a way they would
        // have to repair from outside this app: everything below is a setting being put back, this
        // is a monitor being taken away. The window server does collect a virtual display when the
        // process dies, but that is an undocumented courtesy of a private API and not worth
        // depending on.
        virtualDisplayCreationGeneration &+= 1
        removeAllManagedVirtualDisplays()
        // Cancelled before the restore rather than after, so a check already in flight cannot land
        // on a model that is on its way out and put the switch back on.
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        restoreSleepDisabledIfOurs()
    }

    // MARK: - Capture

    /// What the picture is made of: how many pixels a frame carries, and how many frames a second.
    /// Setters and the persisted defaults live in ``HostModel+Capture.swift``.
    var captureResolution: CaptureResolution = HostModel.storedCaptureResolution()
    var captureFrameRate: CaptureFrameRate = HostModel.storedCaptureFrameRate()
    var captureCodec: VideoCodec = HostModel.storedCaptureCodec()

    // MARK: - Virtual display

    /// Displays made at the phone's request, over ``RemoteCommand/addVirtualDisplay(name:)``.
    ///
    /// **The only way one of these exists.** There used to be a second store beside this one for a
    /// display the Mac's own switch made, free on every plan and restored at launch; creation is the
    /// phone's alone now, and a display nobody asked for is a screen the Mac's user did not make and
    /// cannot take away from the app that did. These are session-scoped: they go when the client
    /// that asked for them does. See `HostModel+VirtualDisplayManagement.swift`.
    var managedVirtualDisplays: [VirtualDisplay] = []

    /// The next serial number a phone-requested display gets.
    ///
    /// The management path derives a distinct product from this number too: the window server
    /// accepted serial-only identities but reset all their modes to 800×600. Only ever counts up: a
    /// display that was removed does not give its serial back, which costs nothing against a
    /// `UInt32` and avoids a reused serial racing the window server's own teardown of the display
    /// that just gave it up.
    var nextManagedVirtualDisplaySerial: UInt32 = 1

    /// Changes whenever teardown invalidates a virtual display currently being constructed.
    /// `VirtualDisplay.init` turns the main run loop, so Stop or Quit can run in the middle of the
    /// call; the creator compares this value before retaining what it made.
    var virtualDisplayCreationGeneration: UInt64 = 0

    /// Nesting depth while Stop/Quit is walking the display collection. Private display waits turn
    /// the main run loop, so one teardown can begin inside another; a depth keeps the outer barrier
    /// raised when the inner call returns.
    var virtualDisplayTeardownDepth = 0
    var isTearingDownVirtualDisplays: Bool { virtualDisplayTeardownDepth > 0 }

    /// Whether the virtual-display collection is being changed right now.
    ///
    /// The wait inside ``VirtualDisplay`` turns the main run loop, so a second click can arrive
    /// while the first display is still being made. Removal can await a capture handoff too. A
    /// second add/remove (or the Mac switch) is dropped during either window so a limit check and a
    /// fallback choice cannot be invalidated by another mutation landing in the middle.
    var isMakingVirtualDisplay = false

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        // There is no useful partial host: without Screen Recording the client receives no picture,
        // without Accessibility its input is silently discarded. Onboarding requests both and calls
        // back here only when they are present.
        guard permissions.allRequiredGranted else {
            status = .idle
            return
        }
        // Before anything opens a session of its own: whatever is in the store at this moment was
        // left by the last process. See ``adoptAbandonedSessions()``.
        adoptAbandonedSessions()
        status = .starting
        if preventLidCloseSleep {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        }
        let device = DeviceIdentity.loadOrCreate(defaultName: Self.defaultDeviceName)
        deviceName = device.name
        deviceID = device.id

        let pins = PinStore(service: "pl.dmq.peering.pins")
        self.pins = pins
        pairedClientIDs = pins.peerIDs

        let identity: SelfSignedIdentity
        do {
            // The common name is decorative — the peer takes the real name from
            // `ServerHello`, so renaming the Mac never invalidates anything.
            identity = try SelfSignedIdentity.loadOrCreate(role: .server, commonName: device.name)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record("Identity unavailable: \(message)", level: .failure)
            return
        }
        self.identity = identity
        record("Identity ready · key \(identity.publicKeyBytes.count) bytes")

        // Until something is being captured there is no captured surface to map into, so the
        // pointer is mapped against the display the user is looking at. That is exactly right for
        // display capture, which is what a client gets if it never picks a source.
        input.transform = DisplayGeometry.activeTransform()

        // Built here but not started: constructing a pipeline only stores the resolver, and reading
        // the catalogue is what needs permission, which happens on the first video connection.
        //
        // The resolver's invalidation callback reaches the coordinator built below it, going through
        // `self` because the callback fires on whatever thread observed the notification and this is
        // the same main-actor hop every other callback here takes.
        // Re-push the catalog when the user switches Spaces, so the number the client's Space picker
        // highlights follows them. The picture of the desktop they arrive on is taken by the
        // resolver on its own schedule, once the switch has finished on screen, and pushes a second
        // catalogue. Neither push stands in for the other.
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator?.refreshCatalog()
        }
        self.spaceObserver = spaceObserver

        let resolver = ScreenCaptureSourceResolver { [weak self] in
            Task { @MainActor [weak self] in self?.coordinator?.refreshCatalog() }
        }
        // Wired here rather than at the cover, because a cover taken back down is the one thing
        // this side of the feature cannot be told about in the call that raised it.
        privacyCurtain.onUncovered = { [weak self] refusals in self?.reportUncovered(refusals) }
        let pipeline = CapturePipeline(resolver: resolver, codec: captureCodec)
        let coordinator = VideoCoordinator(pipeline: pipeline)
        // Before any capture can start: the first video connection may arrive seconds from now, and
        // a coordinator not told would build the first stream of the session from its own defaults.
        // The setters cannot do it from here, since they write to the property below and this
        // coordinator is not that property yet.
        coordinator.setCaptureFormat(
            resolution: captureResolution,
            frameRate: captureFrameRate
        )
        coordinator.onCatalog = { [weak self] catalog in
            Task { @MainActor [weak self] in
                // Kept as well as forwarded: the window names the capture source from it.
                self?.catalog = catalog
                self?.server?.broadcastCatalog(catalog)
            }
        }
        coordinator.onStatus = { [weak self] message in
            Task { @MainActor [weak self] in self?.record(message) }
        }
        coordinator.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(.failed(error.localizedDescription))
                self.announceCaptureProblem(error)
            }
        }
        coordinator.onInputTransform = { [weak self] transform in
            // Straight through, not hopped to the main actor: `input` is not UI state and its
            // `transform` is lock-guarded for exactly this.
            guard let transform else { return }
            self?.input.transform = transform
        }
        // The same value from the only observer that sees it change. For an application or a window
        // this is the authoritative answer: the one above is built from geometry read when capture
        // started, and a window dragged two seconds later has moved since.
        coordinator.onGeometry = { [weak self] geometry in
            guard let transform = geometry.inputTransform else { return }
            self?.input.transform = transform
        }
        coordinator.onSourceChanged = { [weak self] source in
            Task { @MainActor [weak self] in
                self?.capturingSource = source
                // **Raised here rather than at the ask, because the ask is not where a capture
                // starts.** A source asked for while there is no video connection yet is kept and
                // started by the connection that follows, so a phone that has just opened and
                // reconnected captured a window the Mac had never brought to the front: the window
                // was in the stream and behind something else on the Mac, and the first click went
                // to whatever was over it. This is the one door every capture comes through.
                if let source { self?.raiseSource(for: source) }
            }
        }
        self.coordinator = coordinator

        let server = HostServer(identity: identity, device: device, pins: pins, port: port)
        server.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }

        // The server has already established that a live authorized control session holds this
        // client's key. That check is the only thing between an open port and the user's screen,
        // and it is not repeated here.
        server.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }

        // A client whose picture is not arriving asks for it on the control channel, and that
        // request has to reach the pipeline with the connection it arrived on. Straight through,
        // off the main actor: deciding it is a question about sockets and an encoder.
        server.onVideoTransport = { [weak coordinator] clientKey, request, controlPeer in
            coordinator?.setVideoTransport(request, clientKey: clientKey, controlPeer: controlPeer)
        }

        // The same shape for the relay's datagram path: the request comes with the client's key and
        // the allocation the relay handed over, and the answer is the secret that seals what goes on
        // it, or nil, which the session turns into silence and the client reads as "the picture stays
        // where it is".
        server.onVideoKeyRequest = { [weak coordinator] clientKey, relay in
            coordinator?.enableVideoDatagrams(clientKey: clientKey, relay: relay)
        }

        // And the picture's on/off switch, the same shape once more: straight through, off the main
        // actor, because it is a decision about a socket and an encoder. Nothing here ends a session,
        // so a client that asks for no frames keeps its control channel, its shells and the sleep
        // assertion this Mac holds while it is connected, and only the frames stop.
        server.onVideoEnabled = { [weak coordinator] clientKey, enabled in
            coordinator?.setVideoEnabled(enabled, clientKey: clientKey)
        }

        // `input` is captured directly rather than reached through `self`: injecting a mouse move is
        // not UI work, and hopping to the main actor would put every pointer event behind whatever
        // SwiftUI happens to be doing.
        let input = self.input
        server.onCommand = { [weak self] command in
            if case .setCaptureSource(let source) = command {
                Task { @MainActor [weak self] in
                    self?.pendingCaptureSource = source
                    self?.applyCaptureSource(source)
                }
                return
            }
            if case .launchApplication(let bundleIdentifier) = command {
                Task { @MainActor [weak self] in
                    self?.launchApplication(bundleIdentifier: bundleIdentifier)
                }
                return
            }
            if case .reportDeviceOrientation(let isLandscape) = command {
                Task { @MainActor [weak self] in
                    self?.applyDeviceOrientation(isLandscape: isLandscape)
                }
                return
            }
            if case .addVirtualDisplay(let name, let width, let height, let startLandscape) = command {
                Task { @MainActor [weak self] in
                    self?.addVirtualDisplay(
                        name: name,
                        width: width,
                        height: height,
                        startLandscape: startLandscape
                    )
                }
                return
            }
            if case .removeVirtualDisplay(let displayID) = command {
                Task { @MainActor [weak self] in
                    await self?.removeVirtualDisplay(displayID: displayID)
                }
                return
            }
            if case .renameVirtualDisplay(let displayID, let name) = command {
                Task { @MainActor [weak self] in
                    self?.renameVirtualDisplay(displayID: displayID, name: name)
                }
                return
            }
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    // `performSwitch` returns whether the window server *accepted* the move, which
                    // is the whole difference between a tile that works and one that silently does
                    // nothing. The two are indistinguishable from the phone.
                    let switched = switchToSpace(display: display, index: index)
                    self?.record(
                        switched
                            ? "Desktop \(index) on display \(display) accepted"
                            : "Desktop \(index) on display \(display) refused by the window server",
                        level: switched ? .info : .warning
                    )
                }
                return
            }
            if case .switchSpace(let direction) = command {
                Task { @MainActor in
                    switchSpaceRelative(direction: direction)
                }
                return
            }
            if case .setStreamQuality(let fps, let bitrateKbps) = command {
                coordinator.setStreamQuality(fps: fps, bitrateKbps: bitrateKbps)
                return
            }
            if case .refreshSpacePreviews = command {
                // Not hopped to the main actor: the capture is the resolver's own work on its own
                // queue, and the only main-actor part, reading the Space lists, it does itself.
                coordinator.refreshSpacePreviews()
                return
            }
            if case .refreshSourceThumbnails = command {
                // The same shape: the screenshots are taken on the resolver's own tasks and the
                // answer travels on the catalogue push, so nothing here waits.
                coordinator.refreshSourceThumbnails()
                return
            }
            if case .setPrivacyMode(let enabled) = command {
                Task { @MainActor [weak self] in self?.setPrivacyMode(enabled) }
                return
            }
            if case .lockScreen = command {
                Task { @MainActor in
                    let src = CGEventSource(stateID: .hidSystemState)
                    // Keycode 12 is `Q`. 0x19 is `L`, which is silently not the lock shortcut.
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: true)
                    let up   = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: false)
                    down?.flags = [.maskCommand, .maskControl]
                    up?.flags   = [.maskCommand, .maskControl]
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                    hostLog.notice("lock screen shortcut posted")
                }
                return
            }
            // A mosaic takes no input. Every other source is something a click can mean on; a
            // canvas is not, because which machine coordinate a point means depends on which tile
            // it landed in, and the app decides that rather than posting it at the Mac. The client
            // sends nothing while a canvas is up, so this is the belt to that brace: a stray input
            // would otherwise be placed through the last single-source transform, a click on a
            // window nobody is looking at. Selecting a tile is an ordinary source switch.
            if command.isUserInput, coordinator.isShowingMosaic {
                return
            }
            input.perform(command)
        }

        // The reading is asked of the pasteboard rather than of one type on it, because only this
        // end can find out whether what was copied is a picture or a line of text, and the answer
        // decides how it travels. Both hop to the main thread: `NSPasteboard` is not safe from
        // anywhere else, and the session's queue is not the main thread.
        server.onRequestClipboard = {
            DispatchQueue.main.sync { ClipboardPasteboard.read() }
        }
        server.onReceiveClipboard = { payload in
            DispatchQueue.main.async { ClipboardPasteboard.write(payload) }
        }

        self.server = server

        do {
            try server.start()
            let registration = RelayHostRegistration(
                device: device,
                identity: identity,
                onSession: { [weak server] session in server?.connectThroughRelay(session) },
                onStatus: { [weak self] message in
                    Task { @MainActor [weak self] in self?.record(message) }
                }
            )
            server.onPushNeeded = { [weak registration] token, title, message in
                registration?.notifyDevice(token: token, title: title, body: message)
            }
            relayRegistration = registration
            registration.start()

            let watcher = NativeTerminalWatcher()
            watcher.onAttention = { [weak server, weak registration] message in
                let tokens = server?.allPushTokens() ?? []
                // The line that answers "why did nothing arrive": a terminal watched from outside
                // has no session channel to be told over, so the only way this reaches the phone is
                // a token handed over while a session was up. With none there is nothing to send to
                // and nothing on screen to say so.
                if tokens.isEmpty {
                    hostLog.notice("a terminal needs the user and no device token is registered: \(message, privacy: .public)")
                }
                for token in tokens {
                    registration?.notifyDevice(token: token, title: "Terminal needs you", body: message)
                }
            }
            watcher.start()
            nativeTerminalWatcher = watcher
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record(message)
            self.server = nil
        }

        // And no display is made here. A virtual display is a screen this Mac did not have until a
        // phone asked for one, and starting the host is not asking: see ``managedVirtualDisplays``.
    }

    /// Stops listening, and takes everything a session was holding with it.
    ///
    /// A modifier a client left held, the privacy it asked for, the sleep it was keeping off, and
    /// every display it asked this Mac to make: all of it goes, because a stopped host that has left
    /// a monitor behind is the one state the user cannot repair from this window.
    func stop() {
        virtualDisplayTeardownDepth += 1
        defer { virtualDisplayTeardownDepth -= 1 }
        // Before the listener goes, while the reason is still on screen. Stopping is the one
        // disconnect that is not the client's doing, so a modifier held when the user pressed Stop
        // is exactly as stuck as one held by a client that crashed. The sessions cancelled below
        // may or may not report a disconnect of their own, so this does not wait on them.
        input.releaseAll()
        setPrivacyMode(false)
        // Before the listener goes, and before the process can outlive it: a stopped host that has
        // left a monitor behind is the one state the user cannot repair from the window.
        virtualDisplayCreationGeneration &+= 1
        removeAllManagedVirtualDisplays()
        server?.stop()
        server = nil
        relayRegistration?.stop()
        relayRegistration = nil
        nativeTerminalWatcher?.stop()
        nativeTerminalWatcher = nil
        coordinator?.stop()
        coordinator = nil
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        status = .idle
    }

    /// Switches what is being captured, at the client's request.
    ///
    /// The stream is rebuilt for the new source while the video connection is left alone, so the
    /// client sees a new config and keyframe rather than a reconnect. The new source is looked up
    /// at switch time, so one that has since disappeared fails here rather than at connection time,
    /// which is why the failure names the source.
    func applyCaptureSource(_ source: CaptureSource) {
        guard let coordinator else {
            // Nothing is being captured, so there is nothing to switch. The request is kept so the
            // window shows what the client last asked for; a client that has not opened a video
            // connection yet gets the default source, not this one.
            record("Capture source requested before any video connection")
            return
        }

        Task { [weak self] in
            do {
                try await coordinator.switchSource(source)
                self?.pendingCaptureSource = nil
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)", level: .failure)
                // **And the Mac stops offering it.** A source the filter cannot be built for is a
                // source that is not there: the row the phone is looking at is a window that has
                // closed, or one ScreenCaptureKit lists and will not render, and without this the
                // row stays in the picker for as long as the session lasts and every press on it is
                // a press that does nothing at all. Windows and applications only: a display is
                // what a phone needs whatever state it is in. See
                // ``CaptureSourceResolver/markUncapturable(_:)``.
                if let capture = error as? CaptureError, case .sourceUnavailable = capture {
                    switch source {
                    case .window, .application: self?.coordinator?.markUncapturable(source)
                    case .display, .mosaic: break
                    }
                }
            }
        }
    }

    func unpairAll() {
        guard let pins else { return }
        if pins.removeAll() {
            pairedClientIDs = []
            // The names go with the pins: keeping them would leave a device list naming phones it
            // will never let back in.
            clientNames = [:]
            UserDefaults.standard.removeObject(forKey: Self.clientNamesKey)
            // And the tokens, for the same reason and one more: a token is what lets this Mac reach
            // a phone with no session up, so a device that is no longer paired would go on being
            // told about terminals it can no longer open. See ``PushTokenStore``.
            PushTokenStore.shared.forgetAll()
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients", level: .failure)
        }
    }

    /// Revokes one phone without disturbing the others.
    ///
    /// Go through the server while it is running so an already-connected phone is disconnected as
    /// well as removed from the Keychain. Before startup there cannot be an active session, so the
    /// store itself is sufficient.
    /// Drops a phone's connection and leaves it trusted.
    ///
    /// Not forgetful: the pin stays, so the same phone reconnects on its own and no pairing code is
    /// needed. For the case where the session should stop now, because someone else wants the
    /// screen or the wrong device is attached.
    func disconnect(clientID: String) {
        server?.disconnect(clientID: clientID)
        record("Disconnected \(displayName(for: clientID))")
    }

    func unpair(clientID: String) {
        guard let pins else { return }
        let removed = server?.unpair(clientID: clientID) ?? pins.remove(peerID: clientID)
        guard removed else {
            record("Could not remove \(displayName(for: clientID))", level: .failure)
            return
        }

        let name = displayName(for: clientID)
        pairedClientIDs.removeAll { $0 == clientID }
        connectedClients.removeAll { $0.id == clientID }
        clientNames.removeValue(forKey: clientID)
        UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
        // The token goes with the pin. Kept, it would let a phone this Mac no longer trusts be
        // reached with no session up. See ``PushTokenStore``.
        PushTokenStore.shared.forget(clientID: clientID)
        record("Forgot \(name)")
    }

    func refreshPermissions() {
        permissions.refresh()
    }

    // MARK: - Event handling

    private func apply(_ event: HostEvent) {
        switch event {
        case .listening(let port):
            status = .listening(port: port)
            record("Listening on port \(port) as “\(deviceName)”")

        case .stopped:
            status = .idle
            record("Stopped listening")

        case .clientConnected(let clientID, let clientName, let detail):
            if !isConnected(clientID) {
                connectedClients.append(
                    ConnectedClient(id: clientID, name: clientName, since: Date())
                )
            }
            // Recorded before anything is shown, so the name outlives the connection that carried
            // it. Assigned rather than only inserted, because a client may rename itself.
            if clientNames[clientID] != clientName {
                clientNames[clientID] = clientName
                UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
            }
            beginSession(id: clientID, name: clientName)
            startScreenWatch()
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now rather than
            // waiting for an application to launch. It is also the first read of the catalogue,
            // which is what needs Screen Recording permission: a refusal here is logged and ignored,
            // and the video path reports it properly if the client then asks for a source.
            //
            // Immediate, because this client is not a change to the list: it is waiting to ask for
            // the source it was last on, and the interval between pushes would hold that up for as
            // long as three seconds while this Mac captures a display nobody asked for.
            coordinator?.refreshCatalog(immediate: true)
            acquireSleepAssertion()

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty { stopScreenWatch() }
            record("\(clientName) disconnected")
            // The moment nothing is left that can release what this client was holding: a client
            // that dies mid-chord or mid-drag takes its key-up with it, and the Mac would sit
            // holding ⌘ or a mouse button until a real one arrived from the keyboard. Only on the
            // last client, because the held state is the Mac's, so releasing it while another
            // client is connected would drop a modifier that client is holding for real.
            if connectedClients.isEmpty {
                input.releaseAll()
                releaseSleepAssertion()
                setPrivacyMode(false)
                // **And the displays this phone asked for go with it.** A display made at a
                // client's request is that client's, and it is temporary by construction: left
                // behind it is a screen the Mac's own user did not make, cannot take away from the
                // app that made it, and finds again every time they look at the display list. This
                // is the same sentence as the three lines above — nothing is left that can release
                // what the client was holding, so this releases it — and it is here rather than on
                // a command from the phone because a phone that quits, is killed or crashes sends
                // nothing at all. The cost is a client that drops and reconnects losing its extra
                // displays with the connection; they are three taps to make again, and the
                // arrangement they were carrying is a thing the phone remembers how to ask for.
                removeAllManagedVirtualDisplays()
            }

        case .pairingCode(let code, let clientName, let isRemote):
            pairing = PairingPrompt(clientName: clientName, code: code, isRemote: isRemote)
            record(isRemote
                   ? "Pairing request from \(clientName), over the relay"
                   : "Pairing request from \(clientName)")
            // The code is not logged: the unified log is readable by any local process, and the
            // digits are already on screen for the user to compare.
            hostLog.notice("pairing code displayed for \(clientName, privacy: .public)")

        case .pairingCompleted(let clientName, let accepted):
            pairing = nil
            lastOutcome = PairingOutcome(clientName: clientName, accepted: accepted)
            pairedClientIDs = pins?.peerIDs ?? []
            record(accepted ? "Paired with \(clientName)" : "Pairing with \(clientName) rejected")

        case .failed(let message):
            record(message)
            // A failure while listening is worth surfacing as status; a per-connection one is not,
            // or one bad client would blank out a healthy listener.
            if !status.isListening {
                status = .failed(message)
            }
        }
    }

    func record(_ message: String, level: HostLogEntry.Level = .info) {
        // `.public` because these lines are the diagnostics, and the one sensitive value, the
        // pairing code, is deliberately never in them.
        hostLog.notice("\(message, privacy: .public)")
        log.append(HostLogEntry(level: level, message: message))
        if log.count > Self.maxEvents {
            log.removeFirst(log.count - Self.maxEvents)
        }
    }

    /// Darkens every display this Mac can be dark, and covers the rest.
    ///
    /// Two mechanisms, because neither reaches every display. A brightness write is the good one
    /// where it holds: nothing is drawn over the picture, so the phone's stream is untouched by
    /// construction, and the Mac's own brightness-up key still brings the panel back. A display
    /// that will not take the write is covered instead by a window that the window server keeps
    /// out of any capture, which reaches the picture the same way and survives a monitor whose
    /// own firmware refuses what macOS hands it.
    private func setPrivacyMode(_ enabled: Bool) {
        if enabled {
            guard !privacyModeEnabled else { return }
            // Before the cover goes up, so a display that arrives while it is up is not missed:
            // nothing else tells the host that the Mac's display list changed.
            observeDisplayChanges(true)
            privacyModeEnabled = true
            applyPrivacyCover()
        } else {
            guard privacyModeEnabled else {
                // Also repairs a persisted level after an interrupted run.
                displayPrivacy.restore()
                return
            }
            privacyModeEnabled = false
            observeDisplayChanges(false)
            displayPrivacy.restore()
            privacyCurtain.lift()
            record("Privacy Mode off; displays restored")
        }
    }

    /// Dims every display that takes a brightness write, covers the ones that do not, and says
    /// what it managed.
    ///
    /// Called again for a display attached during a session, which is why it works from the
    /// display list rather than from anything remembered: a display nobody has hidden is exactly
    /// what this feature promises not to have.
    private func applyPrivacyCover() {
        let dimmed = (try? displayPrivacy.enable()) ?? []
        let covered = privacyCurtain.cover(
            DisplayPrivacyController.activeDisplayIDs().filter {
                // A display this host made itself has no panel in front of anyone, so there is
                // nothing in front of it to cover.
                !dimmed.contains($0) && VirtualDisplay.name(for: $0) == nil
            }
        )

        let total = dimmed.count + covered.covered.count
        guard total > 0 else {
            let reason = covered.refused.first?.reason ?? "no display here takes a brightness change"
            record("Could not enable Privacy Mode: \(reason)", level: .failure)
            server?.broadcastNotice(NoticePayload(
                message: "Privacy Mode could not darken this Mac's displays.",
                symbol: "display.trianglebadge.exclamationmark"
            ))
            return
        }
        // Said as what happened rather than as a success: a Mac with one third-party monitor dims
        // nothing at all and is still private, and a Mac where the cover failed is not.
        record("""
            Privacy Mode on \(total) display\(total == 1 ? "" : "s") \
            (\(dimmed.count) dimmed, \(covered.covered.count) covered)
            """)
        reportUncovered(covered.refused)
    }

    /// Says, and tells the phone, about a display Privacy Mode left visible.
    ///
    /// Reached twice for one enable: once for a display no cover could be put on at all, and once
    /// from ``DisplayPrivacyCurtain`` for a cover that had to come back down, which the window
    /// server only answers after the call that put it up has returned.
    private func reportUncovered(_ refusals: [DisplayPrivacyCurtain.Refusal]) {
        guard !refusals.isEmpty else { return }
        for refusal in refusals {
            record("Privacy Mode could not cover \(refusal.display): \(refusal.reason)", level: .failure)
        }
        server?.broadcastNotice(NoticePayload(
            message: refusals.count == 1
                ? "One of this Mac's displays is still visible: Privacy Mode could not cover it."
                : "\(refusals.count) of this Mac's displays are still visible: Privacy Mode could not cover them.",
            symbol: "display.trianglebadge.exclamationmark"
        ))
    }

    /// Watches the display list for as long as there is a cover to keep up to date.
    private func observeDisplayChanges(_ observing: Bool) {
        guard observing != (displayObserver == nil) else { return }
        if observing {
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hopped rather than assumed: keeping the covers up to date is main-actor work,
                // and the queue this notification arrives on is not a promise this file can check.
                Task { @MainActor [weak self] in
                    guard let self, self.privacyModeEnabled else { return }
                    self.applyPrivacyCover()
                }
            }
        } else if let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }
    }

    /// The whole log as text, for the window's copy button.
    var logText: String { log.plainText }

    /// Finished sessions, newest first.
    ///
    /// Persisted and bounded: a host running for months should not carry a year of history in
    /// `UserDefaults` to answer a question about this week. Read and written from
    /// ``HostModel+Sessions.swift``.
    var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) }
            .map { Array($0.prefix(HostModel.maxSessions)) } ?? []

    /// Sessions in flight, by client ID — more than one phone can be attached at once. See
    /// ``HostModel/OpenSession``.
    var openSessions: [String: OpenSession] =
        UserDefaults.standard.data(forKey: HostModel.openSessionsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenSession].self, from: $0) } ?? [:]

    /// Whether the store has been checked for what the last process abandoned. Once per process:
    /// after that, anything in ``openSessions`` is one of ours, running.
    var hasAdoptedAbandonedSessions = false

    // MARK: - Sleep prevention

    /// Watches the charge while the lid-close switch is on, and puts normal sleep back when the
    /// battery gets low. Started and stopped from ``HostModel+SleepPrevention.swift``.
    var batteryWatchdog: Task<Void, Never>?

    // MARK: - Device name

    /// The name shown to a client in its device list.
    ///
    /// `Host.current().localizedName` is the "Computer Name" from Sharing settings, which is what
    /// the user recognises. The raw hostname is only a fallback, since a list of those is
    /// unreadable.
    static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
