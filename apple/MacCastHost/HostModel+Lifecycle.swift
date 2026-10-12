import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

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

        guard let identity = loadServerIdentity(for: device) else { return }

        // Until something is captured, map the pointer against the display the user is looking at.
        input.transform = DisplayGeometry.activeTransform()
        observeSpaceChanges()
        startCaptureEnvironmentWatch()

        let coordinator = makeCoordinator()
        self.coordinator = coordinator
        let server = HostServer(identity: identity, device: device, pins: pins, port: port)
        wireVideo(of: server, to: coordinator)
        wireInput(of: server, to: coordinator)
        wireClipboard(of: server)
        self.server = server
        startListening(server, device: device, identity: identity)

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
        let registration = relayRegistration
        if let server {
            // The relay link outlives the listener until the cards' end events have left through it.
            server.stop(afterLiveActivitiesEnd: { registration?.stop() })
        } else {
            registration?.stop()
        }
        server = nil
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
        stopCaptureEnvironmentWatch()
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
