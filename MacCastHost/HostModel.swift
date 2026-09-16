import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import os

/// Host diagnostics, visible with:
/// `log stream --predicate 'subsystem == "pl.dmq.peering.host"'`
///
/// The window is not always reachable — a headless run, a background launch, a user who
/// cannot see the screen — and every failure mode in this app is silent by nature. Logging
/// to the unified log means "the client connected but nothing happened" is answerable
/// without a debugger.
private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Main-actor state for the host window.
///
/// The networking layer knows nothing about SwiftUI and emits ``HostEvent`` values from a
/// background queue; this type is the single place those cross back to the main actor.
/// Keeping that hop in one file means the session state machine never has to reason about
/// actor isolation, and there is exactly one `Task { @MainActor }` to audit rather than a
/// scattering of them.
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

    private(set) var status: Status = .idle
    private(set) var deviceName = ""
    private(set) var deviceID = ""

    /// Present only while a first-time pairing is waiting on the user's comparison.
    private(set) var pairing: PairingPrompt?
    private(set) var lastOutcome: PairingOutcome?

    private(set) var connectedClients: [ConnectedClient] = []
    private(set) var pairedClientIDs: [String] = []

    // Held while at least one client is connected. Released when the last client disconnects.
    // `kIOPMAssertionTypePreventUserIdleSystemSleep` keeps the Mac awake; the display may
    // still dim, but the CPU and network stay live so the session survives a dark screen.
    private var sleepAssertionID: IOPMAssertionID = 0

    // Optional stronger assertion that also prevents lid-close sleep.
    // Uses the same "PreventSystemSleep" type that `caffeinate -s` uses — no admin prompt,
    // automatically released when this process exits (even on crash).
    private var lidSleepAssertionID: IOPMAssertionID = 0
    private(set) var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// Whether a given trusted device is attached right now.
    ///
    /// Matched on the ID, which is the only thing the two lists have in common. The name is the
    /// client's to choose, two devices can present the same one, and comparing it against a list
    /// of IDs is a question that is always false — which is how a connected iPhone came to read
    /// as merely "Trusted".
    func isConnected(_ id: String) -> Bool {
        connectedClients.contains { $0.id == id }
    }
    /// Everything the host has said, newest last.
    ///
    /// Kept as entries rather than as formatted lines so the window can show when each thing
    /// happened and which of them went wrong, and can hand the whole list over in one copy.
    private(set) var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Owned here and driven from two places at once, which is why it is a `@unchecked
    /// Sendable` type with its own lock rather than main-actor state: commands arrive on the
    /// network queue (see the `onCommand` wiring in ``start()``), while the input transform
    /// is written from wherever the coordinator reports one, and the teardown release runs
    /// on the main actor. Hopping either one to the other would put pointer events behind
    /// SwiftUI or the whole UI behind a command queue, so the isolation lives in the type.
    private let input = InputInjector()

    /// Physical display brightness is separate from the captured pixels, which is what lets the
    /// phone keep seeing a Mac whose local panels are dark.
    private let displayPrivacy = DisplayPrivacyController()
    private(set) var privacyModeEnabled = false

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed —
    /// a rejected switch means the client and the host now disagree about what is on screen,
    /// and the window is the only place that disagreement can be seen.
    private(set) var pendingCaptureSource: CaptureSource?

    /// What is actually being streamed, once a switch has been applied.
    ///
    /// The answer to the question someone sitting at the Mac asks first: *what can they see?*
    /// ``pendingCaptureSource`` above is the ask rather than the answer — it is cleared on
    /// success and left set on failure, which makes it useful for spotting a disagreement and
    /// useless for saying what is on screen.
    private(set) var capturingSource: CaptureSource?

    /// The last catalogue the resolver built, kept so a source can be named rather than shown
    /// as a number. A ``CaptureSource`` is a display ID or a pid; "DELL P2212H" is the thing a
    /// person recognizes.
    private(set) var catalog: CaptureCatalog?

    /// The display name of what is being captured, if the catalogue can name it.
    var capturingSourceTitle: String? {
        guard let capturingSource, let catalog else { return nil }
        return catalog.all.first { $0.source == capturingSource }?.title
    }

    /// The last name each device gave when it connected.
    ///
    /// A trusted device is stored as a pin, and a pin is a public key — there is no name in it.
    /// The name arrives with a connection and is gone when it ends, so without keeping it the
    /// device list can only offer an ID for anything not attached right now, and an ID is not
    /// something anyone recognises as their phone.
    ///
    /// Persisted, because the case this exists for is the device that is *not* here: a list
    /// that only names devices while they are connected has forgotten the name by the time it
    /// is needed.
    private(set) var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    private static let clientNamesKey = "Peering.clientNames"

    /// What to call a device: its own name if it has ever said one, otherwise its ID.
    func displayName(for clientID: String) -> String {
        clientNames[clientID] ?? clientID
    }

    /// A still of what is being streamed, for the window's preview.
    ///
    /// `nil` when nothing is being captured. That is the honest answer rather than the last
    /// picture taken — a window still showing a frame from ten minutes ago would be claiming
    /// the phone can see something it cannot.
    ///
    /// The caller decides how often to ask, because the caller is the view: a window that is
    /// closed, or behind another one, has no business taking screenshots of this Mac.
    func snapshot(maxWidth: Int = 640) async -> CGImage? {
        await coordinator?.snapshot(maxWidth: maxWidth)
    }

    /// Capture, encode and send. Deliberately not main-actor bound — see ``VideoCoordinator``.
    /// Nil until the first client opens a video connection, because building one touches the
    /// capture catalogue, which needs Screen Recording permission.
    private var coordinator: VideoCoordinator?

    /// Runs while at least one client is attached. See ``startScreenWatch()``.
    private var screenWatchTask: Task<Void, Never>?

    private var server: HostServer?
    private var relayRegistration: RelayHostRegistration?
    private var pins: PinStore?
    private var identity: SelfSignedIdentity?
    private var spaceObserver: NSObjectProtocol?

    /// A visible tail of what has happened. Bounded because this is a status window, not a
    /// log viewer, and an unbounded array in `@Observable` state re-renders forever.
    private static let maxEvents = 60

    // MARK: - Port

    private static let portKey = "hostPort"

    /// The port this Mac listens on.
    ///
    /// Read once at launch and written when it changes, because a Mac that needs a different
    /// port needs it every time rather than once. Out of range or unset falls back to the
    /// default, so a bad value in the defaults store cannot leave the host unable to start.
    private static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return ProtocolInfo.defaultPort }
        return port
    }

    /// What the menu bar icon should be showing.
    ///
    /// Computed here rather than in the scene, for the reason the scene already gives: an
    /// `@Observable` read inside `MenuBarExtra`'s label is what invalidates it.
    var menuBarState: HostMenuBarState {
        guard status.isListening else { return .stopped }
        if !connectedClients.isEmpty { return .streaming }
        return pairedClientIDs.isEmpty ? .waiting : .ready
    }

    /// What the host is configured to listen on, whether or not it currently is.
    private(set) var port: UInt16 = HostModel.storedPort()

    /// The port that is actually bound, once there is one.
    ///
    /// Preferred over ``port`` for anything shown to the user: the two are the same while the
    /// listener is up, and while it is down the configured value is a claim about the future.
    var boundPort: UInt16 {
        if case .listening(let bound) = status { return bound }
        return port
    }

    /// Changes the port, and restarts the listener if one is running.
    ///
    /// A restart rather than a rebind, because there is no rebinding: the port is fixed when the
    /// listener is created. It is a heavy way to change one number — the capture stream and every
    /// connected device go with it — but the alternative is a host that reports one port and
    /// listens on another, which is worse in every way that matters.
    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort > 0 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)

        guard server != nil else { return }
        stop()
        start()
    }

    // MARK: - Pointer

    private static let enlargePointerKey = "enlargePointer"
    private static let pointerSizeKey = "pointerSize"

    /// Whether a larger pointer is drawn into the video, and how much larger.
    ///
    /// Stored the way ``preventLidCloseSleep`` is, with one difference that is easy to get
    /// wrong: the default is *on*, and `bool(forKey:)` cannot say that — it answers `false`
    /// for a key that was never written, and "never written" is not a decision anybody made.
    /// So the key is read as an object and the absence itself is the default. It is read
    /// twice, once for what the window shows and once for the overlay, because the overlay is
    /// built before there is a window to read it from; the two cannot disagree, since neither
    /// can change without the other being written.
    private static func storedEnlargePointer() -> Bool {
        UserDefaults.standard.object(forKey: enlargePointerKey) as? Bool ?? true
    }

    /// An unreadable size falls back to the default rather than to the smallest, so a value
    /// written by some later version of this app cannot make the pointer too small to see.
    private static func storedPointerSize() -> CursorOverlay.Size {
        UserDefaults.standard.string(forKey: pointerSizeKey)
            .flatMap { CursorOverlay.Size(rawValue: $0) } ?? .medium
    }

    private(set) var enlargePointer: Bool = HostModel.storedEnlargePointer()
    private(set) var pointerSize: CursorOverlay.Size = HostModel.storedPointerSize()

    /// Drawn into every frame, on the capture queue. Held here and shared by reference the way
    /// ``input`` is, and for the same reason: it is read sixty times a second on a thread that
    /// is not this one, so a preference written on the main actor has to reach it without an
    /// actor hop. Keeping those two in step is what the overlay's lock is for.
    private let cursorOverlay = CursorOverlay(
        isEnabled: HostModel.storedEnlargePointer(),
        size: HostModel.storedPointerSize()
    )

    /// Turns the enlarged pointer on or off for the frames already being captured, rather than
    /// for the next session only: whatever is on screen is being watched while the switch is
    /// flipped, and a setting that needed a reconnect to take effect reads as one that did
    /// nothing at all.
    func setEnlargePointer(_ on: Bool) {
        enlargePointer = on
        UserDefaults.standard.set(on, forKey: Self.enlargePointerKey)
        cursorOverlay.isEnabled = on
    }

    func setPointerSize(_ size: CursorOverlay.Size) {
        pointerSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.pointerSizeKey)
        cursorOverlay.size = size
    }

    // MARK: - Capture

    private static let captureResolutionKey = "captureResolution"
    private static let captureFrameRateKey = "captureFrameRate"
    private static let captureCodecKey = "captureCodec"

    /// What the picture is made of: how many pixels a frame carries, and how many frames a
    /// second.
    ///
    /// Both are stored the way ``storedPointerSize()`` is, with a value this version cannot
    /// read falling back to the default rather than to the other case — a key written by some
    /// later build must not be able to leave the stream smaller or slower than anyone chose.
    /// The frame rate needs no absence check the way ``storedEnlargePointer()`` does:
    /// `integer(forKey:)` answers 0 for a key that was never written, and 0 is not a rate any
    /// stream can be built at, so the two cases cannot be confused.
    private static func storedCaptureResolution() -> CaptureResolution {
        UserDefaults.standard.string(forKey: captureResolutionKey)
            .flatMap { CaptureResolution(rawValue: $0) } ?? .full
    }

    private static func storedCaptureFrameRate() -> CaptureFrameRate {
        let stored = UserDefaults.standard.integer(forKey: captureFrameRateKey)
        return CaptureFrameRate(rawValue: stored) ?? .sixty
    }

    private static func storedCaptureCodec() -> VideoCodec {
        UserDefaults.standard.string(forKey: captureCodecKey).flatMap(VideoCodec.init(rawValue:)) ?? .h264
    }

    private(set) var captureResolution: CaptureResolution = HostModel.storedCaptureResolution()
    private(set) var captureFrameRate: CaptureFrameRate = HostModel.storedCaptureFrameRate()
    private(set) var captureCodec: VideoCodec = HostModel.storedCaptureCodec()

    /// These take effect on the next stream, not on the one already running.
    ///
    /// Not a shortcut, and the rows in the window say as much: a surface's size and its frame
    /// interval are fixed when the `SCStream` is built, so a capture already in flight cannot
    /// be changed — it can only be replaced, which would drop the picture and cost a keyframe
    /// for a setting the user is still deciding on. Unlike ``setEnlargePointer(_:)``, which
    /// reaches into the frames already being captured, there is nothing here to reach into.
    func setCaptureResolution(_ resolution: CaptureResolution) {
        captureResolution = resolution
        UserDefaults.standard.set(resolution.rawValue, forKey: Self.captureResolutionKey)
        applyCaptureFormat()
    }

    func setCaptureFrameRate(_ frameRate: CaptureFrameRate) {
        captureFrameRate = frameRate
        UserDefaults.standard.set(frameRate.rawValue, forKey: Self.captureFrameRateKey)
        applyCaptureFormat()
    }

    func setCaptureCodec(_ codec: VideoCodec) {
        captureCodec = codec
        UserDefaults.standard.set(codec.rawValue, forKey: Self.captureCodecKey)
        record("Codec set to \(codec.title); it applies when the next stream starts")
    }

    /// Hands the pair to the coordinator, which reads them when a capture starts.
    ///
    /// Silent while nothing is listening, which is the ordinary case rather than a failure:
    /// the values live in the stored properties above, and ``start()`` gives a coordinator
    /// built afterwards both of them. Written as one call for that reason — a coordinator
    /// that had been told one half of the pair would build the next stream out of two
    /// different moments.
    private func applyCaptureFormat() {
        coordinator?.setCaptureFormat(resolution: captureResolution, frameRate: captureFrameRate)
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        // Before anything opens a session of its own: whatever is in the store at this moment
        // was left by the last process. See ``adoptAbandonedSessions()``.
        adoptAbandonedSessions()
        status = .starting
        permissions.refresh()
        if preventLidCloseSleep { acquireLidSleepAssertion() }
        permissions.requestMissing()

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
        // pointer is mapped against the display the user is actually looking at. That is a
        // reasonable guess rather than a placeholder: it is exactly right for display
        // capture, which is what a client gets if it never picks a source.
        input.transform = DisplayGeometry.activeTransform()

        // Built here but not started. Constructing a pipeline only stores the resolver —
        // reading the catalogue is what needs permission, and that happens on the first
        // video connection.
        //
        // The resolver is handed an invalidation callback that reaches the coordinator built
        // below it. Going through `self` rather than capturing the coordinator directly is
        // what makes that possible without a placeholder: the callback fires on whatever
        // thread observed the notification, and this is the same main-actor hop every other
        // callback in this method already takes.
        // Re-push the catalog when the user switches Spaces so the client's Space picker
        // updates immediately instead of waiting for the next app launch/quit.
        //
        // This push is about the *number* the picker highlights, which has to follow the user
        // as they move. The picture of the desktop they arrive on is taken by the resolver on
        // its own schedule — it has to wait for the switch to finish on screen — and it pushes
        // a second, updated catalogue once it has one. Neither push can stand in for the other.
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
        let pipeline = CapturePipeline(resolver: resolver, codec: captureCodec, overlay: cursorOverlay)
        let coordinator = VideoCoordinator(pipeline: pipeline)
        // Before any capture can start — the first video connection may arrive seconds from
        // now, and a coordinator that had not been told would build the first stream of the
        // session out of its own defaults and quietly disagree with the window. The setters
        // cannot do this from here: they go through ``applyCaptureFormat()``, which writes to
        // the property below, and this coordinator is not that property yet.
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
            Task { @MainActor [weak self] in self?.apply(.failed(error.localizedDescription)) }
        }
        coordinator.onInputTransform = { [weak self] transform in
            // Written straight through rather than hopped to the main actor: `input` is not
            // UI state, and its `transform` is lock-guarded for exactly this reason.
            guard let transform else { return }
            self?.input.transform = transform
        }
        // The same value, from the only observer that sees it change. For an application or a
        // window this is the authoritative answer — the one above is built from geometry read
        // when capture started, and a window dragged two seconds later has moved since. See
        // ``CapturePipeline/inputTransform()``, which asks the callers to prefer this.
        coordinator.onGeometry = { [weak self] geometry in
            guard let transform = geometry.inputTransform else { return }
            self?.input.transform = transform
        }
        coordinator.onSourceChanged = { [weak self] source in
            Task { @MainActor [weak self] in self?.capturingSource = source }
        }
        self.coordinator = coordinator

        let server = HostServer(identity: identity, device: device, pins: pins, port: port)
        server.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }

        // The server has already established that a live authorized control session holds
        // this client's key — that check is the only thing standing between an open port and
        // the user's screen, and it is not repeated here.
        server.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }

        // `input` is captured directly rather than reached through `self`, and deliberately
        // so: injecting a mouse move is not UI work, and hopping to the main actor would put
        // every pointer event behind whatever SwiftUI happens to be doing.
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
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    // The result used to be discarded. `performSwitch` returns whether the
                    // window server *accepted* the move, and that is the whole difference
                    // between a tile that works and one that silently does nothing — the two
                    // are indistinguishable from the phone, and were indistinguishable from
                    // here as well.
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
                // Not hopped to the main actor: the capture is the resolver's own work on its
                // own queue, and the only main-actor thing in it is reading the Space lists,
                // which it does itself. `setStreamQuality` above is the same shape.
                coordinator.refreshSpacePreviews()
                return
            }
            if case .setPrivacyMode(let enabled) = command {
                Task { @MainActor [weak self] in self?.setPrivacyMode(enabled) }
                return
            }
            input.perform(command)
        }

        self.server = server

        do {
            try server.start()
            let registration = RelayHostRegistration(
                device: device,
                onSession: { [weak server] session in server?.connectThroughRelay(session) },
                onStatus: { [weak self] message in
                    Task { @MainActor [weak self] in self?.record(message) }
                }
            )
            relayRegistration = registration
            registration.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record(message)
            self.server = nil
        }
    }

    func stop() {
        // Before the listener goes, while the reason is still on screen. Stopping is the
        // one disconnect that is not the client's doing, so a modifier it was holding when
        // the user pressed Stop is exactly as stuck as one held by a client that crashed.
        // The sessions cancelled below may or may not report a disconnect of their own
        // depending on how far their handshake had got, so this does not wait on them.
        input.releaseAll()
        setPrivacyMode(false)
        server?.stop()
        server = nil
        relayRegistration?.stop()
        relayRegistration = nil
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
    /// The switch happens inside the coordinator: the capture stream is rebuilt for the new
    /// source while the video connection is left alone, so the client sees a new config and
    /// keyframe rather than a reconnect. See ``VideoCoordinator/switchSource(_:)`` for why
    /// the stream is rebuilt instead of having its filter swapped in place. Because the new
    /// source is looked up at switch time, one that has since disappeared fails here rather
    /// than at connection time, which is why the failure names the source.
    private func applyCaptureSource(_ source: CaptureSource) {
        guard let coordinator else {
            // Nothing is being captured, so there is nothing to switch. The request is kept
            // so the window shows what the client last asked for; a client that has not
            // opened a video connection yet will get the default source, not this one.
            record("Capture source requested before any video connection")
            return
        }

        Task { [weak self] in
            do {
                try await coordinator.switchSource(source)
                self?.pendingCaptureSource = nil
                // After the switch rather than before: raising an app whose capture then
                // fails would bring the wrong thing forward and leave it there.
                self?.raiseApplication(for: source)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)", level: .failure)
            }
        }
    }

    /// Brings a captured application to the front, so that what the client sees and where its
    /// clicks land are the same thing.
    ///
    /// Capturing an application is not the same as controlling it, and the gap between the two
    /// is invisible from the client. ScreenCaptureKit composites the app's *windows*; for a
    /// single-window app, `desktopIndependentWindow` captures that window's content exactly, with
    /// no backdrop and no regard for what is drawn over it. So the client sees the app whether it
    /// is occluded, minimised, or on another Space. Input does not work that way: every event goes
    /// to the HID tap, where the window server hit-tests the *real* screen and hands the click to
    /// whatever is genuinely at those coordinates. The user therefore sees the app, clicks where
    /// it appears to be, and hits whatever is actually on top of it — the app looks painted on
    /// rather than present.
    ///
    /// `.activateAllWindows` rather than a plain activation, because ``InputTransform`` for an
    /// application is the union of *every* window it owns: raising only the main one would leave
    /// the transform describing a box that is still partly behind something else.
    ///
    /// The cost is real and worth stating: this moves the app in front of whatever the Mac's own
    /// user was doing, and switches Spaces if its windows are elsewhere. That is what anyone
    /// sitting at the Mac would have to do to use it as well.
    private func raiseApplication(for source: CaptureSource) {
        guard case .application(let pid) = source,
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        running.activate(options: [.activateAllWindows])
    }

    /// Opens a GUI application by the bundle identifier offered in the catalogue, then
    /// follows it into application capture. Executable paths never cross the network.
    private func launchApplication(bundleIdentifier: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            record("Could not launch application: invalid or unavailable bundle identifier", level: .failure)
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.activationPolicy == .regular }) {
            running.activate()
            switchToLaunchedApplication(running)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.record("Could not launch application: \(error.localizedDescription)", level: .failure)
                    return
                }
                guard let application else {
                    self.record("Application launched but no running process was returned", level: .failure)
                    return
                }
                self.record("Opened \(application.localizedName ?? bundleIdentifier)")
                self.coordinator?.refreshCatalog()
                self.switchToLaunchedApplication(application)
            }
        }
    }

    private func switchToLaunchedApplication(_ application: NSRunningApplication) {
        guard let coordinator else {
            record("Application opened; capture is not connected", level: .warning)
            return
        }
        let source = CaptureSource.application(application.processIdentifier)
        pendingCaptureSource = source

        // A launch completion can precede creation of the first capturable window. Poll the
        // observable result instead of assuming that the process being alive means SCK has it.
        Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            var lastError: Error?
            for attempt in 0..<20 {
                do {
                    try await coordinator.switchSource(source)
                    await MainActor.run { self.pendingCaptureSource = nil }
                    return
                } catch {
                    lastError = error
                    if attempt < 19 {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            let message = (lastError as? LocalizedError)?.errorDescription
                ?? lastError.map(String.init(describing:))
                ?? "The application did not expose a capturable window."
            await MainActor.run { self.record("Could not switch to application: \(message)", level: .failure) }
        }
    }

    func unpairAll() {
        guard let pins else { return }
        if pins.removeAll() {
            pairedClientIDs = []
            // The names go with the pins. Keeping them would leave a device list that can name
            // phones it will never let back in, which is a worse answer than not knowing.
            clientNames = [:]
            UserDefaults.standard.removeObject(forKey: Self.clientNamesKey)
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients", level: .failure)
        }
    }

    /// Revokes one phone without disturbing the others.
    ///
    /// Go through the server while it is running so an already-connected phone is disconnected
    /// as well as removed from the Keychain. Before startup there cannot be an active session,
    /// so the store itself is sufficient.
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
            // Recorded before anything is shown, so the name outlives the connection that
            // carried it. A client may rename itself between sessions, which is why this is
            // assigned rather than only inserted.
            if clientNames[clientID] != clientName {
                clientNames[clientID] = clientName
                UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
            }
            beginSession(id: clientID, name: clientName)
            startScreenWatch()
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now
            // rather than waiting for an application to launch. It is also the first read of
            // the catalogue, which is what needs Screen Recording permission — a refusal
            // here is logged and otherwise ignored, and the video path reports it properly
            // if the client then asks for a source.
            coordinator?.refreshCatalog()
            acquireSleepAssertion()

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty { stopScreenWatch() }
            record("\(clientName) disconnected")
            // The moment nothing is left that can release what this client was holding.
            // A client that dies mid-chord or mid-drag takes its key-up with it, and the
            // Mac would otherwise sit holding ⌘ or a mouse button until a real one arrived
            // from the physical keyboard — see ``InputInjector/releaseAll()``, which is
            // where the reasoning lives. Only on the *last* client: the held state is the
            // Mac's, so releasing it while another client is still connected would drop a
            // modifier that client is holding for real.
            if connectedClients.isEmpty {
                input.releaseAll()
                releaseSleepAssertion()
                setPrivacyMode(false)
            }

        case .pairingCode(let code, let clientName):
            pairing = PairingPrompt(clientName: clientName, code: code)
            record("Pairing code for \(clientName): \(code)")

        case .pairingCompleted(let clientName, let accepted):
            pairing = nil
            lastOutcome = PairingOutcome(clientName: clientName, accepted: accepted)
            pairedClientIDs = pins?.peerIDs ?? []
            record(accepted ? "Paired with \(clientName)" : "Pairing with \(clientName) rejected")

        case .failed(let message):
            record(message)
            // A failure while listening is worth surfacing as status; a per-connection
            // failure is not, or one bad client would blank out a healthy listener.
            if !status.isListening {
                status = .failed(message)
            }
        }
    }

    private func record(_ message: String, level: HostLogEntry.Level = .info) {
        // `.public` because these lines are the diagnostics, and the one genuinely sensitive
        // value — the pairing code — is already displayed on screen during pairing.
        hostLog.notice("\(message, privacy: .public)")
        log.append(HostLogEntry(level: level, message: message))
        if log.count > Self.maxEvents {
            log.removeFirst(log.count - Self.maxEvents)
        }
    }

    /// Dims or restores every display for which macOS exposes brightness control.
    private func setPrivacyMode(_ enabled: Bool) {
        if enabled {
            guard !privacyModeEnabled else { return }
            do {
                let count = try displayPrivacy.enable()
                privacyModeEnabled = true
                record("Privacy Mode enabled on \(count) display\(count == 1 ? "" : "s")")
            } catch {
                privacyModeEnabled = false
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                record("Could not enable Privacy Mode: \(message)", level: .failure)
                server?.broadcastNotice(NoticePayload(
                    message: "Privacy Mode could not dim this Mac's displays.",
                    symbol: "display.trianglebadge.exclamationmark"
                ))
            }
        } else {
            guard privacyModeEnabled else {
                // Also repairs a persisted level after an interrupted run.
                displayPrivacy.restore()
                return
            }
            displayPrivacy.restore()
            privacyModeEnabled = false
            record("Privacy Mode disabled; display brightness restored")
        }
    }

    /// The whole log as text, for the window's copy button.
    var logText: String { log.plainText }

    /// Finished sessions, newest first.
    ///
    /// Persisted, and bounded: a host that has been running for months should not carry a
    /// year of history around in `UserDefaults` to answer a question about this week.
    private(set) var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) } ?? []

    /// A session that has begun and has not been written down as finished.
    ///
    /// Persisted as it goes, which is the whole point: a record written only at the end is
    /// lost whenever the end never arrives — the host is quit, crashes, or is rebuilt while a
    /// phone is attached. Those are exactly the sessions someone would want to look up, and
    /// they were the ones going missing.
    private struct OpenSession: Codable {
        var deviceName: String
        var started: Date
        /// The streamer's byte count when this session began. The count is cumulative and
        /// never reset, so a session's cost is the difference between a later read and this.
        var bytesAtStart: Int
        /// The last moment this session was known to be alive. Becomes its end time if no
        /// end ever arrives, which is the honest answer: it was alive then, and nothing since.
        var lastSeen: Date
        /// Bytes counted as of ``lastSeen``. Kept up to date as the session runs rather than
        /// derived at the end, because for a session that never ends there is no end to derive
        /// it from.
        var bytes: Int
    }

    /// Sessions in flight, by client ID — more than one phone can be attached at once.
    private var openSessions: [String: OpenSession] =
        UserDefaults.standard.data(forKey: HostModel.openSessionsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenSession].self, from: $0) } ?? [:]

    private static let sessionsKey = "Peering.sessions"
    private static let openSessionsKey = "Peering.openSessions"
    private static let maxSessions = 20

    private func saveOpenSessions() {
        guard let data = try? JSONEncoder().encode(openSessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.openSessionsKey)
    }

    /// Whatever was in flight when the host last stopped.
    ///
    /// Its presence at launch *is* the signal: nothing else clears this store, so if an entry
    /// survives to a fresh process then a phone was attached when the last one ended, and no
    /// disconnect was ever going to arrive for it.
    /// Whether the store has been checked for what the last process abandoned. Once per
    /// process: after that, anything in `openSessions` is one of *our* sessions, running.
    private var hasAdoptedAbandonedSessions = false

    private func adoptAbandonedSessions() {
        guard !hasAdoptedAbandonedSessions else { return }
        hasAdoptedAbandonedSessions = true
        guard !openSessions.isEmpty else { return }
        // Oldest first, so the list still reads newest-first after each is inserted at the top.
        for open in openSessions.values.sorted(by: { $0.started < $1.started }) {
            record(
                "\(open.deviceName) was still connected when the host last stopped",
                level: .warning
            )
            sessions.insert(
                HostSessionRecord(
                    deviceName: open.deviceName,
                    started: open.started,
                    ended: open.lastSeen,
                    bytes: open.bytes
                ),
                at: 0
            )
        }
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        openSessions = [:]
        saveOpenSessions()
        saveSessions()
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    private func beginSession(id: String, name: String) {
        openSessions[id] = OpenSession(
            deviceName: name,
            started: Date(),
            bytesAtStart: coordinator?.streamStatistics.bytesSent ?? 0,
            lastSeen: Date(),
            bytes: 0
        )
        saveOpenSessions()
        hostLog.notice("session opened for \(id, privacy: .public)")
    }

    /// Keeps the in-flight sessions' figures current.
    ///
    /// Called from the screen watch, which already ticks every two seconds while anybody is
    /// attached. Written every thirtieth tick rather than every one — this is `UserDefaults`,
    /// and a figure that is half a minute stale is worth more than a write per tick.
    private func touchOpenSessions() {
        guard !openSessions.isEmpty, let sent = coordinator?.streamStatistics.bytesSent else { return }
        let now = Date()
        for (id, var open) in openSessions {
            open.lastSeen = now
            open.bytes = max(0, sent - open.bytesAtStart)
            openSessions[id] = open
        }
        saveOpenSessions()
    }

    /// Watches whether the screen being streamed can be seen at all, and says so when it
    /// cannot.
    ///
    /// The failure this removes is silent by construction. A sleeping display still produces a
    /// perfectly healthy stream — frames on time, at full rate, every one of them black — so
    /// from the phone it is indistinguishable from a broken camera, and there is nothing in
    /// the protocol that said otherwise. `notice` is that missing sentence.
    ///
    /// Only ever about a display. An application or a window is drawn by the window server
    /// whether or not a panel is lit, so a picture of one is real with every screen dark —
    /// which is the case that makes this worth saying only for a display.
    private func screenNotice() -> NoticePayload? {
        guard case .display(let id)? = capturingSource else { return nil }

        // Gone rather than dark. `online` is what separates the two: a sleeping display is
        // still connected, and a lid shut with no external screen attached leaves nothing to
        // have a picture of at all. Both arrive at the phone as black, and they are not the
        // same problem — one is a tap away from fixed, the other needs a different source.
        if CGDisplayIsOnline(id) == 0 {
            return NoticePayload(
                message: "That display is no longer connected. Choose another from Sources.",
                symbol: "display.slash"
            )
        }
        if CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0 {
            return NoticePayload(
                message: "This Mac's screen is asleep.",
                symbol: "moon.zzz.fill"
            )
        }
        return nil
    }

    /// Runs ``screenNotice()`` while anyone is attached.
    ///
    /// Nobody attached means nobody to tell, and a host that checks its own screen every two
    /// seconds to say nothing is a host talking to itself.
    private func startScreenWatch() {
        guard screenWatchTask == nil else { return }
        screenWatchTask = Task { [weak self] in
            var announced: NoticePayload?
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }

                // Every thirtieth tick of two seconds, so an abandoned session still has a
                // believable end time and a size rather than a zero.
                ticks += 1
                if ticks % 30 == 0 { self.touchOpenSessions() }

                let notice = self.screenNotice()
                if notice != announced {
                    let wasSayingSomething = announced != nil
                    announced = notice
                    self.server?.broadcastNotice(notice ?? NoticePayload(message: nil))
                    if let message = notice?.message {
                        self.record("Screen not visible · \(message)", level: .warning)
                    } else if wasSayingSomething {
                        // Said so when it went dark, so it owes the all-clear. The warning
                        // above is the one line in this window that resolves itself.
                        self.record("Screen visible again")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopScreenWatch() {
        screenWatchTask?.cancel()
        screenWatchTask = nil
    }

    private func endSession(id: String) {
        guard let open = openSessions.removeValue(forKey: id) else {
            hostLog.notice("session closed for \(id, privacy: .public) with nothing open for it")
            return
        }
        let sent = coordinator?.streamStatistics.bytesSent ?? open.bytesAtStart
        sessions.insert(
            HostSessionRecord(
                deviceName: open.deviceName,
                started: open.started,
                ended: Date(),
                bytes: max(0, sent - open.bytesAtStart)
            ),
            at: 0
        )
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        saveOpenSessions()
        saveSessions()
        hostLog.notice("session recorded · \(self.sessions.count, privacy: .public) kept")
    }

    // MARK: - Sleep prevention

    /// Toggles the lid-close sleep prevention assertion on or off.
    ///
    /// The assertion uses `PreventSystemSleep` — the same type `caffeinate -s` acquires —
    /// which survives closing the lid on most Macs. Unlike a `pmset` change it is
    /// process-scoped: the OS releases it automatically when this process exits, so a crash
    /// can never leave the Mac permanently unable to sleep.
    func setPreventLidCloseSleep(_ on: Bool) {
        preventLidCloseSleep = on
        UserDefaults.standard.set(on, forKey: "preventLidCloseSleep")
        if on {
            acquireLidSleepAssertion()
        } else {
            releaseLidSleepAssertion()
        }
    }

    private func acquireLidSleepAssertion() {
        guard lidSleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacCast lid-close sleep prevention" as CFString,
            &lidSleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire lid sleep assertion (IOReturn \(result, privacy: .public))")
        }
    }

    private func releaseLidSleepAssertion() {
        guard lidSleepAssertionID != 0 else { return }
        IOPMAssertionRelease(lidSleepAssertionID)
        lidSleepAssertionID = 0
    }

    private func acquireSleepAssertion() {
        guard sleepAssertionID == 0 else { return }
        let reason = "MacCast session active" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire sleep assertion (IOReturn \(result, privacy: .public))")
        }
    }

    private func releaseSleepAssertion() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    // MARK: - Device name

    /// The name shown to a client in its device list.
    ///
    /// `Host.current().localizedName` is the "Computer Name" from Sharing settings —
    /// "Damian's MacBook Pro" — which is what the user actually recognises. The raw
    /// hostname (`damians-macbook-pro`) is only a fallback: it is what Bonjour would
    /// advertise by default, and a list of those is unreadable.
    private static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
