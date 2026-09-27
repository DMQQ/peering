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
        // **Starting again is the user asking to be reachable**, so it takes back the release
        // ``stop()`` performed and puts the keep-awake through the schedule like every other path,
        // which outside the window is to hold nothing yet.
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

        let resolver = ScreenCaptureSourceResolver { [weak self] immediate in
            Task { @MainActor [weak self] in
                self?.coordinator?.refreshCatalog(immediate: immediate)
            }
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
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // `switchToSpace` returns whether the window server *accepted* the move, which
                    // is the difference between a tile that works and one that silently does
                    // nothing. Whether the *picture* followed is the other half of the answer, and
                    // it arrives later or not at all: see ``report(spaceSwitchRoute:index:display:)``.
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
            offDesktopGate.pass(command, source: coordinator.source)
        }

        // The reading is asked of the pasteboard rather than of one type on it, because only this
        // end can find out whether what was copied is a picture or a line of text, and the answer
        // decides how it travels. Both hop to the main thread: `NSPasteboard` is not safe from
        // anywhere else, and the session's queue is not the main thread.
        server.onRequestClipboard = {
            DispatchQueue.main.sync { ClipboardPasteboard.read() }
        }
        server.onReceiveClipboard = { payload in
            // Synchronous, so a ⌘V sent straight after the push pastes what was pushed.
            DispatchQueue.main.sync { ClipboardPasteboard.write(payload) }
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
            watcher.onAttention = { [weak server, weak registration] message, windowID in
                let tokens = server?.allPushTokens() ?? []
                // The line that answers "why did nothing arrive": a terminal watched from outside
                // has no session channel to be told over, so the only way this reaches the phone is
                // a token handed over while a session was up. With none there is nothing to send to
                // and nothing on screen to say so.
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
        // **Nothing is being hosted, so the Mac is not being held up for anybody.** This is the
        // clearest possible statement of "nobody is using it": the user has said so themselves.
        // Released through the ordinary path, which leaves the switches where they were, so
        // starting again is what puts the keep-awake back rather than a setting to go and find.
        Task { await releaseKeepAwakeNow() }
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
}
