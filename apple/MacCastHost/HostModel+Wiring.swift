import AppKit
import Foundation
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// What ``HostModel/start()`` connects: the server's callbacks to the pipeline and the model, and the relay and terminal watching that follow once it listens.
extension HostModel {
    func loadServerIdentity(for device: DeviceIdentity) -> SelfSignedIdentity? {
        let identity: SelfSignedIdentity
        do {
            // The common name is decorative, the peer takes the real name from
            // `ServerHello`, so renaming the Mac never invalidates anything.
            identity = try SelfSignedIdentity.loadOrCreate(role: .server, commonName: device.name)
        } catch {
            Analytics.failed(error, in: .network)
            let message = HostFailureText.resource(for: error)
            status = .failed(message)
            record("Identity unavailable: \(message)", level: .failure)
            return nil
        }
        self.identity = identity
        record("Identity ready · key \(identity.publicKeyBytes.count) bytes")
        return identity
    }

    /// Re-pushes the catalogue when Spaces switch so the client Space picker follows; the resolver takes the new desktop picture later and pushes a second catalogue.
    func observeSpaceChanges() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.refreshCatalog() }
        }
    }

    /// Built but not started: reading the catalogue needs permission, which happens on the first video connection.
    func makeCoordinator() -> VideoCoordinator {
        let resolver = ScreenCaptureSourceResolver { [weak self] immediate in
            Task { @MainActor [weak self] in
                self?.coordinator?.refreshCatalog(immediate: immediate)
            }
        }
        // Wired here because a cover taken back down cannot be reported in the call that raised it.
        privacyCurtain.onUncovered = { [weak self] refusals in self?.reportUncovered(refusals) }
        let pipeline = CapturePipeline(resolver: resolver, codec: captureCodec)
        let coordinator = VideoCoordinator(pipeline: pipeline)
        // Before any capture starts, or the first stream would be built from the coordinator defaults; the setters cannot do it as this coordinator is not yet the property.
        coordinator.setCaptureFormat(
            resolution: captureResolution,
            frameRate: captureFrameRate
        )
        coordinator.onCatalog = { [weak self] catalog in
            Task { @MainActor [weak self] in
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
                HostTelemetry.capture(error)
                self.apply(.failed(verbatim: error.localizedDescription))
                self.announceCaptureProblem(error)
            }
        }
        coordinator.onCaptureRestored = { [weak self] in
            Task { @MainActor [weak self] in self?.captureWasRestored() }
        }
        coordinator.onInputTransform = { [weak self] transform in
            // Straight through, not hopped to the main actor: `input` is not UI state and its
            // `transform` is lock-guarded for exactly this.
            self?.input.transform = transform
        }
        // The authoritative geometry for an application or window: the value above was read when capture started and a dragged window has moved since.
        coordinator.onGeometry = { [weak self] geometry in
            guard let transform = geometry.inputTransform else { return }
            self?.input.transform = transform
        }
        coordinator.onSourceChanged = { [weak self] source in
            Task { @MainActor [weak self] in
                self?.capturingSource = source
                // Raised here, not at the ask: a source asked for before a video connection is started by the connection that follows, which would otherwise capture a window the Mac never brought to the front.
                if let source { self?.raiseSource(for: source) }
            }
        }
        return coordinator
    }

    func wireVideo(of server: HostServer, to coordinator: VideoCoordinator) {
        server.callbacks.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }
        // The server has already established that an authorized control session holds this client key; not repeated here.
        server.callbacks.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }
        // Straight through, off the main actor: it concerns sockets and an encoder, and must reach the pipeline with the connection it arrived on.
        server.callbacks.onVideoTransport = { [weak coordinator] clientKey, request, controlPeer in
            coordinator?.setVideoTransport(request, clientKey: clientKey, controlPeer: controlPeer)
        }
        // The relay datagram path: the answer is the sealing secret, or nil, which the session turns into silence.
        server.callbacks.onVideoKeyRequest = { [weak coordinator] clientKey, relay in
            coordinator?.enableVideoDatagrams(clientKey: clientKey, relay: relay)
        }
        // Nothing here ends a session: a client asking for no frames keeps its control channel, shells and the sleep assertion.
        server.callbacks.onVideoEnabled = { [weak coordinator] clientKey, enabled in
            coordinator?.setVideoEnabled(enabled, clientKey: clientKey)
        }
        server.callbacks.onClientVideoCodecs = { [weak coordinator] clientKey, codecs in
            coordinator?.setDeclaredVideoCodecs(codecs, clientKey: clientKey)
        }
    }

    func wireInput(of server: HostServer, to coordinator: VideoCoordinator) {
        // Captured directly, not through self: hopping to the main actor would put every pointer event behind SwiftUI.
        let input = self.input
        let textFocusWatcher = self.textFocusWatcher
        let offDesktopGate = OffDesktopInputGate { command in
            input.perform(command)
            if case .mouseUp(.left) = command {
                textFocusWatcher.clicked(at: input.clickLocation)
            }
        }
        server.callbacks.onCommand = { [weak self] command in
            if Self.dispatch(command, to: self, coordinator: coordinator) { return }
            // A mosaic takes no input: which machine coordinate a point means depends on the tile, which the app decides. The client sends nothing while a canvas is up, so this is a backstop against input placed through a stale single-source transform.
            if command.isUserInput, coordinator.isShowingMosaic { return }
            offDesktopGate.pass(command, source: coordinator.source)
        }
    }

    func wireClipboard(of server: HostServer) {
        // Asked of the pasteboard, not one type: only this end can tell a picture from text. Hops to the main thread because NSPasteboard is not safe elsewhere.
        server.callbacks.onRequestClipboard = { reply in
            DispatchQueue.main.async { reply(ClipboardPasteboard.read()) }
        }
        // The session holds later commands until `done`, so a ⌘V sent straight after the push pastes what was pushed without the network queue waiting on the main thread.
        server.callbacks.onReceiveClipboard = { payload, done in
            DispatchQueue.main.async {
                ClipboardPasteboard.write(payload)
                done()
            }
        }
    }

    /// Opens the listener; on success the relay, the terminal watcher and the hooks follow it, on failure the model says why and drops the server.
    func startListening(_ server: HostServer, device: DeviceIdentity, identity: SelfSignedIdentity) {
        do {
            try server.start()
            PostHogLog.info("remote host started", attributes: [
                "component": "host_server",
            ])
            let registration = registerWithRelay(server, device: device, identity: identity)
            watchTerminals(server: server, registration: registration)
            terminalHooks.attach(
                tokens: { [weak server] in server?.allPushTokens() ?? [] },
                push: { [weak registration] token, title, body, action in
                    registration?.notifyDevice(token: token, title: title, body: body, action: action)
                }
            )
            server.externalApprovalResolver = terminalHooks.resolver
        } catch {
            Analytics.failed(error, in: .network)
            let message = HostFailureText.resource(for: error)
            status = .failed(message)
            record(message)
            Analytics.serverStartFailed()
            PostHogLog.error("remote host failed to start", attributes: [
                "failure_stage": "server_start",
            ])
            self.server = nil
        }
    }

    private func registerWithRelay(_ server: HostServer, device: DeviceIdentity, identity: SelfSignedIdentity) -> RelayHostRegistration {
        let registration = RelayHostRegistration(
            device: device,
            identity: identity,
            onSession: { [weak server] session in server?.connectThroughRelay(session) },
            onStatus: { [weak self] message in
                Task { @MainActor [weak self] in self?.record(message) }
            }
        )
        server.callbacks.onPushNeeded = { [weak registration] token, title, message in
            registration?.notifyDevice(token: token, title: title, body: message)
        }
        server.callbacks.onAgentPushNeeded = { [weak registration] token, title, message, action in
            registration?.notifyDevice(token: token, title: title, body: message, action: action)
        }
        server.callbacks.onActivityPush = { [weak registration] push, done in
            guard let registration else { return done() }
            registration.notifyActivity(push, completion: done)
        }
        registration.onActivityRefused = { [weak server] reason, requestId in
            server?.activityPushRefused(reason, requestId: requestId)
        }
        server.callbacks.onAgentActivity = { [weak self] active in
            Task { @MainActor [weak self] in self?.setAgentActivity(active) }
        }
        relayRegistration = registration
        registration.start()
        return registration
    }

    private func watchTerminals(server: HostServer, registration: RelayHostRegistration) {
        let watcher = NativeTerminalWatcher()
        watcher.onAttention = { [weak server, weak registration] message, windowID in
            let tokens = server?.allPushTokens() ?? []
            // A terminal watched from outside has no session channel, so only a token handed over while a session was up can reach the phone.
            if tokens.isEmpty {
                hostLog.notice("a terminal needs the user and no device token is registered: \(message, privacy: .public)")
            }
            for token in tokens {
                registration?.notifyDevice(
                    token: token,
                    title: String(localized: "Terminal needs you"),
                    body: message,
                    source: windowID.map { CaptureSource.window($0).stableID }
                )
            }
        }
        watcher.start()
        nativeTerminalWatcher = watcher
    }
}
