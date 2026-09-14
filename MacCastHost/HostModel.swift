import Foundation
import Observation
import RemoteCore
import os

/// Host diagnostics, visible with:
/// `log stream --predicate 'subsystem == "pl.dmq.maccast.host"'`
///
/// The window is not always reachable — a headless run, a background launch, a user who
/// cannot see the screen — and every failure mode in this app is silent by nature. Logging
/// to the unified log means "the client connected but nothing happened" is answerable
/// without a debugger.
private let hostLog = Logger(subsystem: "pl.dmq.maccast.host", category: "session")

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

    private(set) var connectedClients: [String] = []
    private(set) var pairedClientIDs: [String] = []
    private(set) var events: [String] = []

    let permissions = Permissions()

    /// Owned here and driven from two places at once, which is why it is a `@unchecked
    /// Sendable` type with its own lock rather than main-actor state: commands arrive on the
    /// network queue (see the `onCommand` wiring in ``start()``), while the input transform
    /// is written from wherever the coordinator reports one, and the teardown release runs
    /// on the main actor. Hopping either one to the other would put pointer events behind
    /// SwiftUI or the whole UI behind a command queue, so the isolation lives in the type.
    private let input = InputInjector()

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed —
    /// a rejected switch means the client and the host now disagree about what is on screen,
    /// and the window is the only place that disagreement can be seen.
    private(set) var pendingCaptureSource: CaptureSource?

    /// Capture, encode and send. Deliberately not main-actor bound — see ``VideoCoordinator``.
    /// Nil until the first client opens a video connection, because building one touches the
    /// capture catalogue, which needs Screen Recording permission.
    private var coordinator: VideoCoordinator?

    private var server: HostServer?
    private var pins: PinStore?
    private var identity: SelfSignedIdentity?

    /// A visible tail of what has happened. Bounded because this is a status window, not a
    /// log viewer, and an unbounded array in `@Observable` state re-renders forever.
    private static let maxEvents = 60

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        status = .starting
        permissions.refresh()
        permissions.requestMissing()

        let device = DeviceIdentity.loadOrCreate(defaultName: Self.defaultDeviceName)
        deviceName = device.name
        deviceID = device.id

        let pins = PinStore(service: "pl.dmq.maccast.pins")
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
            record("Identity unavailable: \(message)")
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
        let resolver = ScreenCaptureSourceResolver { [weak self] in
            Task { @MainActor [weak self] in self?.coordinator?.refreshCatalog() }
        }
        let pipeline = CapturePipeline(resolver: resolver)
        let coordinator = VideoCoordinator(pipeline: pipeline)
        coordinator.onCatalog = { [weak self] catalog in
            Task { @MainActor [weak self] in self?.server?.broadcastCatalog(catalog) }
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
        self.coordinator = coordinator

        let server = HostServer(identity: identity, device: device, pins: pins)
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
            guard case .setCaptureSource(let source) = command else {
                input.perform(command)
                return
            }
            Task { @MainActor [weak self] in
                self?.pendingCaptureSource = source
                self?.applyCaptureSource(source)
            }
        }

        self.server = server

        do {
            try server.start()
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
        server?.stop()
        server = nil
        coordinator?.stop()
        coordinator = nil
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
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)")
            }
        }
    }

    func unpairAll() {
        guard let pins else { return }
        if pins.removeAll() {
            pairedClientIDs = []
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients")
        }
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

        case .clientConnected(let clientName, let detail):
            if !connectedClients.contains(clientName) {
                connectedClients.append(clientName)
            }
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now
            // rather than waiting for an application to launch. It is also the first read of
            // the catalogue, which is what needs Screen Recording permission — a refusal
            // here is logged and otherwise ignored, and the video path reports it properly
            // if the client then asks for a source.
            coordinator?.refreshCatalog()

        case .clientDisconnected(let clientName):
            connectedClients.removeAll { $0 == clientName }
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

    private func record(_ message: String) {
        // `.public` because these lines are the diagnostics, and the one genuinely sensitive
        // value — the pairing code — is already displayed on screen during pairing.
        hostLog.notice("\(message, privacy: .public)")
        events.append(message)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

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
