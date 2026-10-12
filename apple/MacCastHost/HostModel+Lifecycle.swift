import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

extension HostModel {
    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        // No useful partial host: without Screen Recording there is no picture, without Accessibility input is discarded.
        guard permissions.allRequiredGranted else {
            status = .idle
            return
        }
        // Before anything opens a session of its own: whatever is in the store at this moment was
        // left by the last process. See ``adoptAbandonedSessions()``.
        adoptAbandonedSessions()
        status = .starting
        // Starting again takes back the release stop() performed and goes through the schedule, which outside its window holds nothing.
        Task { await rearmKeepAwake() }
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
            Analytics.failed(error, in: .network)
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record("Identity unavailable: \(message)", level: .failure)
            return
        }
        self.identity = identity
        record("Identity ready · key \(identity.publicKeyBytes.count) bytes")

        // Until something is captured, map the pointer against the display the user is looking at.
        input.transform = DisplayGeometry.activeTransform()

        // Built but not started: reading the catalogue needs permission, which happens on the first video connection.
        // Re-push the catalogue when Spaces switch so the client Space picker follows; the resolver takes the new desktop picture later and pushes a second catalogue.
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.refreshCatalog() }
        }
        self.spaceObserver = spaceObserver

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
                self.apply(.failed(error.localizedDescription))
                self.announceCaptureProblem(error)
            }
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
        self.coordinator = coordinator

        let server = HostServer(identity: identity, device: device, pins: pins, port: port)
        server.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }

        // The server has already established that an authorized control session holds this client key; not repeated here.
        server.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }

        // Straight through, off the main actor: it concerns sockets and an encoder, and must reach the pipeline with the connection it arrived on.
        server.onVideoTransport = { [weak coordinator] clientKey, request, controlPeer in
            coordinator?.setVideoTransport(request, clientKey: clientKey, controlPeer: controlPeer)
        }

        // The relay datagram path: the answer is the sealing secret, or nil, which the session turns into silence.
        server.onVideoKeyRequest = { [weak coordinator] clientKey, relay in
            coordinator?.enableVideoDatagrams(clientKey: clientKey, relay: relay)
        }

        // Nothing here ends a session: a client asking for no frames keeps its control channel, shells and the sleep assertion.
        server.onVideoEnabled = { [weak coordinator] clientKey, enabled in
            coordinator?.setVideoEnabled(enabled, clientKey: clientKey)
        }

        server.onClientVideoCodecs = { [weak coordinator] clientKey, codecs in
            coordinator?.setDeclaredVideoCodecs(codecs, clientKey: clientKey)
        }

        // Captured directly, not through self: hopping to the main actor would put every pointer event behind SwiftUI.
        let input = self.input
        let textFocusWatcher = self.textFocusWatcher
        let offDesktopGate = OffDesktopInputGate { command in
            input.perform(command)
            if case .mouseUp(.left) = command {
                textFocusWatcher.clicked(at: input.clickLocation)
            }
        }
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
            if case .performWindowAction(let windowID, let action) = command {
                Task { @MainActor [weak self] in
                    self?.performWindowAction(action, windowID: windowID)
                }
                return
            }
            if case .openNewWindow(let bundleIdentifier) = command {
                Task { @MainActor [weak self] in
                    self?.openNewWindow(bundleIdentifier: bundleIdentifier)
                }
                return
            }
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // switchToSpace returns whether the window server accepted the move; whether the picture followed arrives later, see report(spaceSwitchRoute:index:display:).
                    _ = switchToSpace(display: display, index: index) { route in
                        Task { @MainActor in
                            self.report(spaceSwitchRoute: route, index: index, display: display)
                        }
                    }
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
                // Not hopped: the capture is the resolver's own work on its own queue.
                coordinator.refreshSpacePreviews()
                return
            }
            if case .refreshSourceThumbnails = command {
                coordinator.refreshSourceThumbnails()
                return
            }
            if case .watchSourceThumbnails(let watching) = command {
                coordinator.watchSourceThumbnails(watching)
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
            // A mosaic takes no input: which machine coordinate a point means depends on the tile, which the app decides. The client sends nothing while a canvas is up, so this is a backstop against input placed through a stale single-source transform.
            if command.isUserInput, coordinator.isShowingMosaic {
                return
            }
            offDesktopGate.pass(command, source: coordinator.source)
        }

        // Asked of the pasteboard, not one type: only this end can tell a picture from text. Hops to the main thread because NSPasteboard is not safe elsewhere.
        server.onRequestClipboard = { reply in
            DispatchQueue.main.async { reply(ClipboardPasteboard.read()) }
        }
        // The session holds later commands until `done`, so a ⌘V sent straight after the push pastes what was pushed without the network queue waiting on the main thread.
        server.onReceiveClipboard = { payload, done in
            DispatchQueue.main.async {
                ClipboardPasteboard.write(payload)
                done()
            }
        }

        self.server = server

        do {
            try server.start()
            PostHogLog.info("remote host started", attributes: [
                "component": "host_server",
            ])
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
            server.onAgentPushNeeded = { [weak registration] token, title, message, action in
                registration?.notifyDevice(token: token, title: title, body: message, action: action)
            }
            server.onActivityPush = { [weak registration] push, done in
                guard let registration else { return done() }
                registration.notifyActivity(push, completion: done)
            }
            registration.onActivityRefused = { [weak server] reason in
                server?.activityPushRefused(reason)
            }
            server.onAgentActivity = { [weak self] active in
                Task { @MainActor [weak self] in self?.setAgentActivity(active) }
            }
            relayRegistration = registration
            registration.start()

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
                        title: "Terminal needs you",
                        body: message,
                        source: windowID.map { CaptureSource.window($0).stableID }
                    )
                }
            }
            watcher.start()
            nativeTerminalWatcher = watcher

            terminalHooks.attach(
                tokens: { [weak server] in server?.allPushTokens() ?? [] },
                push: { [weak registration] token, title, body, action in
                    registration?.notifyDevice(token: token, title: title, body: body, action: action)
                }
            )
            server.externalApprovalResolver = terminalHooks.resolver
        } catch {
            Analytics.failed(error, in: .network)
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record(message)
            Analytics.serverStartFailed()
            PostHogLog.error("remote host failed to start", attributes: [
                "failure_stage": "server_start",
            ])
            self.server = nil
        }

        // No display is made here: starting the host is not a phone asking for one, see managedVirtualDisplays.
    }

    /// Takes a held modifier, privacy, sleep prevention and every requested display with it: a monitor left behind is not repairable from this window.
    func stop() {
        virtualDisplayTeardownDepth += 1
        defer { virtualDisplayTeardownDepth -= 1 }
        // Before the listener goes: a modifier held when Stop is pressed is as stuck as one from a crashed client, and the cancelled sessions may not report a disconnect.
        input.releaseAll()
        setPrivacyMode(false, counted: false)
        // Nothing is hosted, so nobody needs the Mac held up. Released through the ordinary path, so starting again puts the keep-awake back.
        Task { await releaseKeepAwakeNow() }
        // Before the listener goes: a monitor left behind is not repairable from the window.
        virtualDisplayCreationGeneration &+= 1
        removeAllManagedVirtualDisplays()
        server?.stop()
        server = nil
        relayRegistration?.stop()
        relayRegistration = nil
        nativeTerminalWatcher?.stop()
        nativeTerminalWatcher = nil
        terminalHooks.detach()
        coordinator?.stop()
        coordinator = nil
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        status = .idle
    }

    /// The stream is rebuilt while the video connection is kept, so the client sees a new config and keyframe. The source is looked up at switch time, so a vanished one fails here and the failure names it.
    func applyCaptureSource(_ source: CaptureSource) {
        // The first source of a session is the starting point, not a change.
        if let previous = lastCountedCaptureSource, previous != source {
            Analytics.track(.captureSourceChanged)
        }
        lastCountedCaptureSource = source
        guard let coordinator else {
            // Nothing is captured, so the request is kept only for the window; a client with no video connection gets the default source.
            record("Capture source requested before any video connection")
            return
        }

        Task { [weak self] in
            do {
                try await coordinator.switchSource(source)
                self?.pendingCaptureSource = nil
            } catch {
                Analytics.failed(error, in: .capture)
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)", level: .failure)
                // And the Mac stops offering it: a window that closed or one ScreenCaptureKit lists but will not render would otherwise stay in the picker as a dead row. Windows and applications only. See CaptureSourceResolver/markUncapturable(_:).
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
        Analytics.track(.unpairedAll)
        guard let pins else { return }
        if server?.unpairAll() ?? pins.removeAll() {
            pairedClientIDs = []
            // Names go with the pins, or the device list would name phones it will never let back in.
            clientNames = [:]
            UserDefaults.standard.removeObject(forKey: Self.clientNamesKey)
            // And the tokens: a token lets this Mac reach a phone with no session, so an unpaired device would keep being told about terminals. See PushTokenStore.
            PushTokenStore.shared.forgetAll()
            relayRegistration?.dropAllPending()
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients", level: .failure)
        }
    }

    func resolvePairing(approved: Bool) {
        guard let sessionID = pairing?.sessionID else { return }
        server?.resolvePairingApproval(sessionID: sessionID, approved: approved)
    }

    /// Drops a connection but leaves the phone trusted: the pin stays, so it reconnects without a pairing code.
    func disconnect(clientID: String) {
        Analytics.track(.clientDisconnected)
        server?.disconnect(clientID: clientID)
        record("Disconnected \(displayName(for: clientID))")
    }

    func unpair(clientID: String) {
        Analytics.track(.unpaired)
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
        // The token goes with the pin, or a phone no longer trusted could still be reached with no session up.
        if let token = PushTokenStore.shared.token(for: clientID) { relayRegistration?.dropPending(token: token) }
        PushTokenStore.shared.forget(clientID: clientID)
        record("Forgot \(name)")
    }

    func refreshPermissions() {
        permissions.refresh()
    }
}
