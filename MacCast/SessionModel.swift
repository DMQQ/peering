import Foundation
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

private let modelLog = Logger(subsystem: "pl.dmq.maccast", category: "app")

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
        Macro(id: "copy", title: "⌘C", keyCode: 8, modifiers: .command),
        Macro(id: "paste", title: "⌘V", keyCode: 9, modifiers: .command),
        Macro(id: "cut", title: "⌘X", keyCode: 7, modifiers: .command),
        Macro(id: "undo", title: "⌘Z", keyCode: 6, modifiers: .command),
        Macro(id: "save", title: "⌘S", keyCode: 1, modifiers: .command),
        Macro(id: "close", title: "⌘W", keyCode: 13, modifiers: .command),
        Macro(id: "appswitch", title: "⌘⇥", keyCode: 48, modifiers: .command),
        Macro(id: "spotlight", title: "⌘Space", keyCode: 49, modifiers: .command),
        Macro(id: "escape", title: "esc", keyCode: 53, modifiers: []),
        Macro(id: "return", title: "⏎", keyCode: 36, modifiers: []),
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
    private var identity: SelfSignedIdentity?
    private var device = DeviceIdentity(id: "", name: "")
    private var session: ClientSession?
    private var videoPoll: Task<Void, Never>?

    init() {
        device = DeviceIdentity.loadOrCreate(defaultName: UIDevice.current.name)
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
            browseStatus = "Looking for Macs on this network…"
        case .updated(let hosts):
            self.hosts = hosts
            browseStatus = hosts.isEmpty
                ? "No Macs found yet. Make sure MacCastHost is running and on the same network."
                : "\(hosts.count) Mac\(hosts.count == 1 ? "" : "s") found"
        case .failed(let message):
            // Bonjour failing is silent on iOS without the local-network permission and the
            // NSBonjourServices entry, so the message is surfaced verbatim rather than
            // smoothed over — the manual address path below is the way past it.
            browseStatus = "Browsing failed: \(message)"
        }
    }

    // MARK: - Connecting

    /// Whether a session is up or on its way up. The same question as ``Phase/holdsSession`` —
    /// asked once, answered in one place.
    var isBusy: Bool { phase.holdsSession }

    func connect(to target: ClientSession.Target) {
        guard let identity, identityFailure == nil else { return }
        hostName = target.displayName
        activeSourceID = nil
        catalog = nil
        notes.removeAll()
        videoStatus = "No video stream"

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
            self.phase = phase
            if case .failed(let message) = phase {
                videoStatus = "Stopped: \(message)"
            }
            if phase == .disconnected {
                videoStatus = "Disconnected"
            }
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
        case .config(let config):
            // The decoder half of this is done on the network queue, in the same place the
            // frames are handled, so that it is ordered against them — see the event handler
            // in `connect(to:)`. Flushing and reconfiguring here instead would put the reset
            // *after* a keyframe that arrived in the same read, and throw that keyframe away.
            // Only the labels belong on the main actor.
            videoStatus = "\(config.codec.rawValue.uppercased()) \(config.pixelWidth)×\(config.pixelHeight)"
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
        case .ended(let reason):
            videoStatus = "Video ended: \(reason)"
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
        session?.confirmPairing(accepted: accepted)
    }

    func disconnect() {
        session?.disconnect()
        session = nil
        videoPoll?.cancel()
        videoPoll = nil
        renderer.reset()
        latchedModifiers = []
        phase = .disconnected
    }

    /// Forgets the pin for a Mac. The Mac keeps its half, so the next connection is refused
    /// by it until it is unpaired on that side too — which is the honest behaviour for
    /// "forget", as opposed to a silent re-pair.
    func forget(hostID: String) {
        pins.remove(hostID: hostID)
        append(note: "Forgot \(hostID). Unpair this device on the Mac as well.")
    }

    var pairedHostIDs: [String] { pins.hostIDs }

    /// Destroys this device's identity key and mints a fresh one under a new device ID.
    ///
    /// Both, not just the key. A Mac that already holds a pin for this client ID will only
    /// ever accept the key it pinned, so rotating the key alone locks the device out of every
    /// Mac it has paired with. Changing the ID as well makes this device a stranger again,
    /// which is what "start over" has to mean.
    func resetDeviceIdentity() {
        session?.disconnect()
        session = nil
        phase = .disconnected
        do {
            try SelfSignedIdentity.destroy(role: .client)
        } catch {
            append(note: "Could not destroy the old key: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return
        }
        _ = pins.removeAll()

        UserDefaults.standard.removeObject(forKey: "MacCast.deviceID")
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

    /// Text from the software keyboard, routed by the current mode.
    func handleTypedText(_ text: String) {
        guard !text.isEmpty else { return }
        typedPreview = String((typedPreview + text).suffix(40))

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
    var holdsSession: Bool {
        switch self {
        case .connecting, .handshaking, .confirming, .ready: return true
        case .idle, .failed, .disconnected: return false
        }
    }
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
