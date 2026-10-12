import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    /// - Parameter old: the session this attempt supersedes, removed rather than pruned since two entries for one Mac read as "it connected twice".
    func connect(
        to target: ClientSession.Target,
        replacing old: MacSession?,
        timeout: TimeInterval = SessionModel.standardConnectTimeout,
        racingRelay relay: ClientSession.Target? = nil
    ) {
        CrashLog.note("dial \(Self.hostID(of: target) ?? "unknown")\(old == nil ? "" : ", replacing a session") · \(sessions.count) open")
        guard let identity, identityFailure == nil else { return }

        // A Mac already open is brought to the front, not dialled again: two sessions would be two clients on the Mac. Every route passes here.
        // Not for a ladder putting a Mac back: `old` is how it says so.
        if old == nil, let hostID = Self.hostID(of: target),
           let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }

        // The screen goes to the Mac from the first frame of the connecting card, so a stepped-away session dialled again does not leave the picker up behind it.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // Said rather than silently refused: the ceiling is a fact about this phone, and a tap that did nothing would read as broken.
        if old == nil, openSessions.count >= Self.sessionCeiling {
            append(note: String(localized: "This device holds \(Self.sessionCeiling) Macs open at once. Close one to open another."))
            return
        }

        // Remembered for the widget, which can offer to connect but cannot know to what. Written twice: the app reads its own defaults, the widget only the shared container.
        UserDefaults.standard.set(target.displayName, forKey: Self.lastHostNameKey)
        SharedStore.lastHostName = target.displayName
        // A widget is not told anything, so without this it keeps showing the previous Mac until the system refreshes it.
        WidgetCenter.shared.reloadAllTimelines()

        // An attempt from the backoff timer would race this one and start a second session.
        stopReconnecting()
        // A session already up is torn down rather than replaced: assigning over it leaves the first connection running unheld, so the peer sees it drop mid-handshake, which with a retry is a loop.
        activeSession?.connectTask?.cancel()
        activeSession?.connectTask = nil
        activeSession?.wire?.disconnect()
        // The user has just asked to reach a Mac, the first moment "tell you when it needs you?" means anything.
        notifier.prepareForFirstConnect()

        let session = MacSession(model: self, renderer: renderer)

        // Cleared for every new session: a punched path belongs to the session that proved it, and a stale `true` would report a direct path not in use.
        session.usedDirectPath = false
        switch target {
        case .discovered(let host):
            session.connectionPath = .lan
            remotePairingHostID = nil
            UserDefaults.standard.set(host.id, forKey: Self.lastHostIDKey)
            rememberLANHost(host)
        case .relay(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = nil
            UserDefaults.standard.set(hostID, forKey: Self.lastHostIDKey)
        case .relayPairing(let hostID, _, _):
            session.connectionPath = .relay
            remotePairingHostID = hostID
            // Nothing is proven to be this Mac yet, so nothing is remembered as the last Mac: a half-typed ID would be dialled again by the ladder.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        case .address:
            session.connectionPath = .direct
            remotePairingHostID = nil
            // The handshake replaces this with the real ID; a different Mac's ID in the window could make a retry dial the relay for the wrong machine.
            UserDefaults.standard.removeObject(forKey: Self.lastHostIDKey)
        }
        if old == nil {
            switch target {
            case .discovered: Analytics.connectStarted(route: .discovered)
            case .relay: Analytics.connectStarted(route: .relay)
            case .relayPairing: Analytics.connectStarted(route: .pairing)
            case .address: Analytics.connectStarted(route: .address)
            }
        }
        // Fresh for the path this session just chose: the policy's tier is tuned per path.
        session.autoQualityPolicy = AutoQualityPolicy(path: session.autoQualityPath)
        session.lastAutoDroppedFrames = 0
        session.beginRoute(.init(session.connectionPath))

        // Two facts belong to the Mac, not this attempt, and are carried across a dial of that Mac only.
        // `hasBeenReady` tells a resume from a first connection: the ladder builds a new object, so otherwise a blip would put the connecting card back.
        // `reconnectAttempt` is carried because the object is replaced on every attempt, or a failing Mac would stay on the first rung.
        // The third fact cannot be carried from `old`: a cold launch's restoration has no session behind it, so the intent arrives on the model. See `isComingBack`.
        session.isComingBack = isResuming

        if let old, let targetID = target.hostID, targetID == old.hostID {
            session.hasBeenReady = old.hasBeenReady
            session.reconnectAttempt = old.reconnectAttempt
            // And the clock the window is measured on: the run of attempts is one run however many objects it spans.
            session.reconnectingSince = old.reconnectingSince

            // Only a retry the app made: a manual connect starts the drop count, the tallies and the route list again.
            if isResuming { session.telemetry = old.telemetry.carriedToRetry() }

            // And which source was on screen: the Mac keeps capturing the same display across a client reconnect, so forgetting it would make `PictureIdentity` read a different picture and `RemoteScreen` reset zoom and pan.
            // The catalogue is deliberately not carried: the Mac resends it on `.ready`, and a stale one naming gone sources is worse than none.
            session.activeSourceID = old.activeSourceID

            // The arrangement choices, not `isAskingForMosaic` or `askedMosaicLayout`: those are side effects of asking, and the reconnect's catalogue-triggered re-ask (`pendingSourceReassertion`) writes them from these. Uncarried, `activeSourceID` named the arrangement while nothing else agreed: no borders, no tile taps, no way back.
            session.mosaicChoices = old.mosaicChoices

            // The renderer and screen survive a reconnect, so the description of the picture they show must too, or the grid looks intact but has no overlay or hit targets until a matching config arrives. The next source-tagged config replaces it.
            session.pictureMosaicLayout = old.pictureMosaicLayout
        }

        // The episode begins with the dial, not only a rung: a restoration and the relay-to-LAN handover dial with no ladder, so a dial that never answers is otherwise unbounded. See `reconnectWindow`.
        if isResuming, session.reconnectingSince == nil {
            session.reconnectingSince = Date()
        }

        session.hostName = target.displayName

        let race = relay == nil ? nil : DialRace(session: session)
        session.dialRace = race
        let (wire, gate) = makeWire(for: session, identity: identity, race: race)
        let resumeSource = old?.hostID == target.hostID ? old?.sourceToResume : nil
        wire.resumeSource = resumeSource
        session.wire = wire
        place(session, replacing: old)
        publishOpenMacs()

        // Whether a missing picture could be a network blocking video depends on where the Mac is: Bonjour means this network, while the relay and a typed address cross networks nobody here controls.
        // On the relay the picture shares the control channel, so asking there reduces rate rather than moving.
        wire.videoFallbackEnabled = session.connectionPath != .lan
        session.startVideoPolling()

        let connectTask = Task { [weak session, weak wire] in
            guard let wire else { return }
            await wire.connect(to: target, timeout: timeout)
            await MainActor.run {
                guard session?.wire === wire else { return }
                session?.connectTask = nil
            }
        }
        session.connectTask = connectTask

        if let race, let relay {
            race.add(wire, gate: gate, path: session.connectionPath ?? .lan)
            race.startLater(after: Self.relayHeadStart) { [weak self, weak session] in
                guard let self, let session, session.dialRace === race else { return }
                let (rival, rivalGate) = self.makeWire(for: session, identity: identity, race: race)
                race.add(rival, gate: rivalGate, path: .relay)
                session.beginRoute(.relay)
                rival.resumeSource = resumeSource
                rival.videoFallbackEnabled = true
                Task { await rival.connect(to: relay, timeout: Self.standardConnectTimeout) }
            }
        }
    }

    /// The LAN is free so it gets the first chance, but a Mac on the same network answers well within this.
    static let relayHeadStart: Duration = .milliseconds(300)

    private func makeWire(
        for session: MacSession,
        identity: SelfSignedIdentity,
        race: DialRace?
    ) -> (ClientSession, WireGate) {
        // Bound outside the closure (network queue). Frames and configs go straight to the renderer's queue in wire order: hopping the main actor would put a 60 Hz stream behind layout.
        let renderer = self.renderer
        let gate = WireGate(admitted: race == nil)
        let box = WeakWire()
        let wire = ClientSession(
            identity: identity,
            clientID: device.id,
            clientName: device.name,
            pins: pins,
            onEvent: { [weak session, weak race] event in
                let admitted: Bool
                if case .video(let video) = event {
                    switch video {
                    case .frame(let frame):
                        if gate.pass(video: video) { renderer.enqueue(frame) }
                        return
                    case .config(let config):
                        admitted = gate.pass(video: video)
                        if admitted { renderer.configure(config) }
                    default:
                        admitted = gate.isAdmitted
                    }
                } else {
                    admitted = gate.isAdmitted
                }
                if admitted {
                    Task { @MainActor in session?.apply(event) }
                } else {
                    let wire = box.wire
                    Task { @MainActor in if let wire { race?.receive(event, from: wire) } }
                }
            }
        )
        box.wire = wire
        return (wire, gate)
    }
}

private nonisolated final class WeakWire: @unchecked Sendable {
    weak var wire: ClientSession?
}
