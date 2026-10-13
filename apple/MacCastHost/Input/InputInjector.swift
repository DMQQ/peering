import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RemoteCore
import os

let inputLog = Logger(subsystem: "pl.dmq.peering.host", category: "input")

/// Every posting call is gated on Accessibility trust: without it CGEvent.post is a silent no-op, so a client connects and nothing happens.
/// The transform is behind a lock because it changes mid-session (source switch, window moved or resized).
final class InputInjector: @unchecked Sendable {
    let lock = NSLock()
    var _transform: InputTransform?
    /// Only ever a clamped position, so clicks, drags and scroll-at-cursor can reuse it. The initial zero is read only by a click before any move.
    private var cursor: CGPoint = .zero

    var clickLocation: CGPoint { lock.withLock { cursor } }

    /// When the last joystick nudge arrived. See the `.joystickMove` case: it is what separates
    /// the first nudge of a gesture from the rest of one.
    private var lastJoystickAt: DispatchTime?
    private var settleReport: DispatchWorkItem?
    /// Told where the pointer ended up once the joystick has been still, since the phone only has an estimate built from the nudges it sent. Guarded by `lock`.
    var onJoystickSettled: (@Sendable (CGPoint) -> Void)?
    private var lastJoystickPostedAt: DispatchTime?
    private var pendingJoystickDx: Double = 0
    private var pendingJoystickDy: Double = 0

    private static let joystickResyncGap: UInt64 = 250_000_000
    /// Nanoseconds between posted mouseMoved events (about 83 Hz): a burst guard sitting below the client's 60 Hz interval (16.7 ms), since a threshold at the interval makes jitter alternate small and double steps.
    private static let joystickPostInterval: UInt64 = 12_000_000

    // One shared source avoids allocating per event; hidSystemState reads modifier state correctly.
    let eventSource = CGEventSource(stateID: .hidSystemState)
    var hasWarnedUntrusted = false

    /// Which modifiers the system believes are held; a modifier must be released explicitly (see postKey).
    var heldModifiers: Modifiers = []

    /// Modifiers a chord pressed itself, so its key-up releases only those and not one the client toggled on.
    var chordEngaged: [UInt16: Modifiers] = [:]

    /// Buttons pressed and not yet released, in press order. A lost mouse-up leaves a button down so the user's next physical click completes the client's drag; an array so release is in reverse press order.
    private var heldButtons: [MouseButton] = []

    /// From the mouse-down of a command-drag until the mouse-up, including while the AX lookup runs and after it returns nothing: moves meanwhile are not posted as pointer moves, and the mouse-up is not posted as a release.
    var windowMove: WindowMove?

    var nextWindowMoveID: UInt64 = 0

    /// Not the network queue: an Accessibility call to an unresponsive application blocks until the API timeout, and a window drag asks sixty times a second, which would stall the picture and control channel. Serial because a window drag is a state machine across commands.
    let windowMoveQueue = DispatchQueue(label: "pl.dmq.peering.host.input.window-move")

    /// System-wide: the point is to find whatever is under the pointer in any application.
    let systemWide = AXUIElementCreateSystemWide()

    /// Bounded because the chain is read from another process a call at a time; a loop would never return.
    static let maximumAncestorDepth = 32

    /// The modifier keys in the order a chord presses them; a chord releases them in reverse.
    /// This is the order a physical keyboard produces, and some applications match on it.
    static let modifierKeys: [(bit: Modifiers, code: UInt16)] = [
        (.control, 59),
        (.option, 58),
        (.shift, 56),
        (.command, 55),
    ]

    private let isTrusted: @Sendable () -> Bool

    /// - Parameter isTrusted: injectable so the refusal path can be exercised. The default
    ///   is the real check; nothing else about this type should be mocked.
    init(
        transform: InputTransform? = nil,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self._transform = transform
        self.isTrusted = isTrusted
    }

    /// The mapping currently in force. Set to `nil` when no capture source is known, which
    /// makes every pointer command a no-op rather than sending the cursor to a stale place.
    var transform: InputTransform? {
        get { lock.withLock { _transform } }
        set {
            lock.withLock {
                // Frames report geometry sixty times a second, nearly always unchanged; comparing here avoids the lock and memory traffic per frame.
                guard _transform != newValue else { return }
                _transform = newValue
            }
        }
    }

    func perform(_ command: RemoteCommand) {
        guard isTrusted() else {
            warnUntrustedOnce()
            return
        }

        switch command {
        case .mouseMove(let point):
            guard let location = location(for: point) else { return }
            // Recorded even when the move is swallowed: the next click, drag or scroll posts here, and leaving it at the grab would land the first click where the window used to be.
            let moveID = lock.withLock { () -> (UInt64?, MouseButton?) in
                cursor = location
                return (windowMove?.id, heldButtons.last)
            }
            let held = moveID.1
            guard let moveID = moveID.0 else {
                postMouse(moveType(holding: held), at: location, button: cgButton(held ?? .left))
                return
            }
            // Posted and the window carried too: the window position is computed from cursor, not from what was posted, so both move by the same delta. Swallowing the move left the drawn pointer parked at the grab while the window slid away, since the overlay draws from the live cursor.
            postMouse(moveType(holding: held), at: location, button: cgButton(held ?? .left))

            windowMoveQueue.async { [weak self] in
                self?.applyWindowMove(to: location, id: moveID)
            }

        case .mouseDown(let button):
            // The last posted position, not the live cursor: a click must land where the user is looking, which is the drawn position.
            let location = lock.withLock { cursor }

            // A command-drag is a window move, armed by the Move button latching the command bit. Decided at press and kept until the button comes up even if command is released. Nothing is posted and no button recorded held, so the mouse-up is not a release for a press that never went out.
            if button == .left, lock.withLock({ heldModifiers.contains(.command) }) {
                beginWindowMove(from: location)
            } else {
                lock.withLock { if !heldButtons.contains(button) { heldButtons.append(button) } }
                postMouse(mouseType(for: button, pressed: true), at: location, button: cgButton(button))
            }

        case .mouseUp(let button):
            let location = lock.withLock { cursor }
            lock.withLock { heldButtons.removeAll { $0 == button } }
            // The mouse-up ending a window move posts nothing: no mouse-down went out, so it would be a release with no press that whatever is under the cursor acts on.
            if button == .left, endWindowMove() { return }
            postMouse(mouseType(for: button, pressed: false), at: location, button: cgButton(button))

        case .scroll(let dx, let dy):
            // Vertical is wheel1, horizontal wheel2. The sign is flipped here: the client delta is positive-downward while the wheel reads positive toward the end of the document.
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: InputEncoding.wheelValue(-dy),
                wheel2: InputEncoding.wheelValue(-dx),
                wheel3: 0
            ) else {
                return
            }
            // Placed at the drawn position: an event with no location routes to the live cursor, so nudging the physical mouse could scroll a different window silently.
            event.location = lock.withLock { cursor }
            event.post(tap: .cghidEventTap)

        case .keyDown(let keyCode, let modifiers):
            if modifiers.contains(.topRowAction), let key = MediaKey(functionKeyCode: keyCode) {
                postMediaKey(key)
            } else {
                postKey(code: keyCode, down: true, modifiers: modifiers.subtracting(.topRowAction))
            }

        case .keyUp(let keyCode, let modifiers):
            if modifiers.contains(.topRowAction), MediaKey(functionKeyCode: keyCode) != nil { break }
            postKey(code: keyCode, down: false, modifiers: modifiers.subtracting(.topRowAction))

        case .textInput(let text):
            postText(text)

        case .lockScreen:
            // Control-Command-Q is the documented Lock Screen shortcut; going through the same gated path keeps it inside the granted permission.
            postKey(code: 12, down: true, modifiers: [.control, .command])
            postKey(code: 12, down: false, modifiers: [.control, .command])
            inputLog.notice("lock screen shortcut posted")

        case .switchSpace:
            // Never reached: HostModel routes this to switchSpaceRelative first. Injected Ctrl+arrows are consumed by the window server before they act, but a chord posted through Accessibility is honoured (SpaceReader.performSwitch posts one). Kept as an explicit no-op because the command still exists on the wire.
            break

        case .joystickMove(let dx, let dy):
            guard dx.isFinite, dy.isFinite else { return }
            let now = DispatchTime.now()

            let postTarget: CGPoint? = lock.withLock {
                let idle = lastJoystickAt.map { now.uptimeNanoseconds - $0.uptimeNanoseconds } ?? .max
                lastJoystickAt = now

                let origin: CGPoint
                if idle > Self.joystickResyncGap {
                    // Start of a new gesture: pick up wherever the physical mouse is.
                    pendingJoystickDx = 0
                    pendingJoystickDy = 0
                    origin = CGEvent(source: eventSource)?.location ?? cursor
                } else {
                    origin = cursor
                }

                pendingJoystickDx += dx
                pendingJoystickDy += dy

                // Posting rate capped (about 60 Hz), deltas carried forward: posting at .cghidEventTap every frame floods the window server and stutters everything, including display redraws.
                let sincePost = lastJoystickPostedAt.map { now.uptimeNanoseconds - $0.uptimeNanoseconds } ?? .max
                guard sincePost >= Self.joystickPostInterval else { return nil }

                lastJoystickPostedAt = now
                let pdx = pendingJoystickDx
                let pdy = pendingJoystickDy
                pendingJoystickDx = 0
                pendingJoystickDy = 0
                // Clamped: the origin is wherever the physical mouse was left, and a joystick has no idea where it pushes to, so unclamped it walks off the content and keeps walking.
                let target = clamped(CGPoint(x: origin.x + pdx, y: origin.y + pdy), to: _transform)
                cursor = target
                return target
            }

            if let target = postTarget {
                postMouse(.mouseMoved, at: target, button: .left)
            }
            scheduleSettleReport()

        case .setCaptureSource, .launchApplication, .switchToSpace, .setStreamQuality,
             .setVideoEnabled, .refreshSpacePreviews, .refreshSourceThumbnails, .watchSourceThumbnails,
             .setPrivacyMode, .requestClipboard, .pushClipboard, .pushClipboardImage, .reportDeviceOrientation,
             .addVirtualDisplay, .removeVirtualDisplay, .renameVirtualDisplay,
             .performWindowAction, .openNewWindow:
            // Handled upstream, in the host's own routing, before this method is called.
            break
        }
    }

    private static let joystickSettleDelay: TimeInterval = 0.3

    private func scheduleSettleReport() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The post rate cap holds back a nudge that arrives soon after another, and nothing follows the last one to carry it: without this the pointer stops short of where the phone drew it.
            let (tail, report, location) = lock.withLock { () -> (CGPoint?, (@Sendable (CGPoint) -> Void)?, CGPoint) in
                var tail: CGPoint?
                if pendingJoystickDx != 0 || pendingJoystickDy != 0 {
                    let target = clamped(CGPoint(x: cursor.x + pendingJoystickDx, y: cursor.y + pendingJoystickDy), to: _transform)
                    pendingJoystickDx = 0
                    pendingJoystickDy = 0
                    cursor = target
                    tail = target
                }
                return (tail, onJoystickSettled, cursor)
            }
            if let tail { postMouse(.mouseMoved, at: tail, button: .left) }
            let real = CGEvent(source: nil)?.location ?? location
            inputLog.notice("joystick settled · tail \(tail != nil, privacy: .public) · pointer off by \(Int(hypot(real.x - location.x, real.y - location.y))) pt")
            report?(location)
        }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let old = settleReport
            settleReport = item
            return old
        }
        previous?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.joystickSettleDelay, execute: item)
    }

    // MARK: - Teardown

    /// Releases what the client left held. A client dropping between key down and up leaves the window server believing the modifier is pressed (every later keystroke becomes a shortcut), and a lost mouse-down makes the next physical click complete the client's drag.
    /// Called when the last client goes: held state belongs to the Mac and cannot be attributed to one client, and releasing it under another client would drop a modifier it holds for real.
    /// Deliberately not gated on Accessibility trust: it only undoes events, and while untrusted nothing was ever held.
    /// A window move in progress is dropped too, and the window left where the last move put it. Dropped before the guard because the guard returns when nothing is held, and command can be released first, leaving a grab that would swallow the next session's pointer moves.
    func releaseAll() {
        lock.withLock { windowMove = nil }
        let held = lock.withLock { () -> (buttons: [MouseButton], modifiers: Modifiers) in
            let snapshot = (buttons: heldButtons, modifiers: heldModifiers)
            heldButtons.removeAll()
            chordEngaged.removeAll()
            return snapshot
        }
        // Nothing to undo: a flags change with no change, or a mouse-up for a button never pressed, invents input (a real event a view under the cursor acts on).
        guard !held.buttons.isEmpty || !held.modifiers.isEmpty else { return }

        // Through transition so each bit is released along a real chord's path, with the resulting state, in reverse press order.
        for (bit, _) in Self.modifierKeys.reversed() {
            transition(bit, down: false)
        }

        let location = lock.withLock { cursor }
        for button in held.buttons.reversed() {
            postMouse(mouseType(for: button, pressed: false), at: location, button: cgButton(button))
        }

        inputLog.notice("""
            released input a client left held · \
            \(held.modifiers.rawValue, privacy: .public) modifier bits, \
            \(held.buttons.count, privacy: .public) button(s)
            """)
    }




}
