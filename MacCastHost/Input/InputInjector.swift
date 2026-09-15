import ApplicationServices
import CoreGraphics
import Foundation
import RemoteCore
import os

private let inputLog = Logger(subsystem: "pl.dmq.peering.host", category: "input")

/// Posts synthetic input into the session.
///
/// **Every posting call is gated on Accessibility trust, and that gate is not defensive
/// padding.** Without the permission `CGEvent.post` is a *silent no-op*: no error, no
/// exception, no return value to check — the cursor simply does not move and keystrokes
/// vanish. An app that assumes it worked is indistinguishable from one that is broken, and
/// the only external symptom is "the client connects but nothing happens".
///
/// The transform is held behind a lock rather than being fixed at init because it changes
/// mid-session: switching capture source, or the captured window being moved or resized,
/// both replace the mapping from client coordinates to screen coordinates.
final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var _transform: InputTransform?
    private var cursor: CGPoint = .zero

    /// When the last joystick nudge arrived. See the `.joystickMove` case: it is what separates
    /// the first nudge of a gesture from the rest of one.
    private var lastJoystickAt: DispatchTime?
    /// When we last actually posted a mouse-moved event for a joystick nudge.
    private var lastJoystickPostedAt: DispatchTime?
    /// Accumulated delta not yet posted because the posting rate was capped.
    private var pendingJoystickDx: Double = 0
    private var pendingJoystickDy: Double = 0

    /// How long a quiet gap makes the next joystick nudge the start of a new gesture.
    private static let joystickResyncGap: UInt64 = 250_000_000
    /// Minimum nanoseconds between posted mouseMoved events (≈ 83 Hz).
    ///
    /// This is a burst guard, not a rate limit, and the distinction is the whole of its value.
    /// The client sends its accumulated joystick delta at 60 Hz — one sample every 16.7 ms — so
    /// a threshold *at* 16.7 ms sits exactly on the interval it is meant to be judging: jitter
    /// of a millisecond either way decides whether a sample goes now or waits and travels with
    /// the next one, and the cursor advances in alternating small and double steps. Sitting
    /// below the interval means every sample clears it and goes immediately, while a genuine
    /// burst is still capped.
    ///
    /// The ceiling it enforces is unchanged in practice. Posting still happens at the client's
    /// rate, sixty times a second, which is what the cap was always aiming for.
    private static let joystickPostInterval: UInt64 = 12_000_000

    // Reusing a single source avoids allocating a new CGEventSource on every event.
    // hidSystemState reflects the current HID state so modifier keys are read correctly.
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var hasWarnedUntrusted = false

    /// Which modifiers the system currently believes are held. Necessary because a modifier
    /// has to be *released* explicitly — see ``postKey(code:down:modifiers:)``.
    private var heldModifiers: Modifiers = []

    /// The modifiers a chord pressed itself, per key, so its key-up releases only those.
    /// Without this a chord containing a modifier the client had toggled on would switch
    /// that toggle off on its way out.
    private var chordEngaged: [UInt16: Modifiers] = [:]

    /// Mouse buttons the client has pressed and not yet released, in press order.
    ///
    /// Tracked for the same reason as ``heldModifiers``, and it is the worse of the two to
    /// leave behind: a drag whose mouse-up never arrives keeps a button down on the Mac, so
    /// the next thing the user physically clicks completes *the client's* drag instead. An
    /// array rather than a set so the release order is the reverse of the press order, which
    /// is what a real mouse does and what makes the teardown deterministic.
    private var heldButtons: [MouseButton] = []

    /// The modifier keys in the order a chord presses them; a chord releases them in reverse.
    /// This is the order a physical keyboard produces, and some applications match on it.
    private static let modifierKeys: [(bit: Modifiers, code: UInt16)] = [
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
                // A frame reports its geometry sixty times a second and it is almost always the
                // one already in force, so the comparison lives here rather than at each call
                // site — the per-frame writer would otherwise take the lock and touch memory on
                // every frame of a stream that is usually standing still.
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
            lock.withLock { cursor = location }
            postMouse(.mouseMoved, at: location, button: .left)

        case .mouseDown(let button):
            // Uses the position we last posted, not the live cursor. If the user nudges the
            // physical mouse between the client's move and its click, the live cursor is no
            // longer where the client is drawing it — and a click has to land where the
            // user is looking, which is the drawn position.
            let location = lock.withLock { cursor }
            lock.withLock { if !heldButtons.contains(button) { heldButtons.append(button) } }
            postMouse(mouseType(for: button, pressed: true), at: location, button: cgButton(button))

        case .mouseUp(let button):
            let location = lock.withLock { cursor }
            lock.withLock { heldButtons.removeAll { $0 == button } }
            postMouse(mouseType(for: button, pressed: false), at: location, button: cgButton(button))

        case .scroll(let dx, let dy):
            // Vertical is wheel1 and horizontal is wheel2.
            //
            // The sign is flipped here rather than at the client, because the client's delta is
            // only a statement of which way the fingers moved, and this is the sole place that
            // knows what a `CGEvent` wheel delta means. Passed through unchanged, a downward
            // two-finger drag scrolled the Mac the opposite way from the fingers — the delta
            // reads positive-downward and the wheel reads positive-toward-the-end-of-the-document.
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
            event.post(tap: .cghidEventTap)

        case .keyDown(let keyCode, let modifiers):
            postKey(code: keyCode, down: true, modifiers: modifiers)

        case .keyUp(let keyCode, let modifiers):
            postKey(code: keyCode, down: false, modifiers: modifiers)

        case .textInput(let text):
            postText(text)

        case .switchSpace:
            // Never reached, and deliberately so. `HostModel` matches this command before it
            // gets here and routes it to `switchSpaceRelative`, which moves the desktop through
            // the window server directly.
            //
            // This used to post Ctrl+←/Ctrl+→, on the theory that the real Spaces shortcut is
            // handled by the window server and needs no target application's cooperation. That
            // part is true; the events simply were not honoured — the window server consumes
            // symbolic hot keys before an injected chord reaches it, which is why the route was
            // abandoned for the direct call. Left as an explicit no-op rather than deleted,
            // because the command still exists on the wire and a future reader deserves to know
            // which side handles it.
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

                // Cap the posting rate at ≈ 60 Hz. Accumulated deltas are carried forward so
                // no movement is lost, only batched. Posting at .cghidEventTap on every frame
                // at 30 Hz floods the window server and causes progressive stuttering as its
                // internal queue fills up and everything — including display redraws — slows.
                let sincePost = lastJoystickPostedAt.map { now.uptimeNanoseconds - $0.uptimeNanoseconds } ?? .max
                guard sincePost >= Self.joystickPostInterval else { return nil }

                lastJoystickPostedAt = now
                let pdx = pendingJoystickDx
                let pdy = pendingJoystickDy
                pendingJoystickDx = 0
                pendingJoystickDy = 0
                let target = CGPoint(x: origin.x + pdx, y: origin.y + pdy)
                cursor = target
                return target
            }

            if let target = postTarget {
                postMouse(.mouseMoved, at: target, button: .left)
            }

        case .setCaptureSource, .launchApplication, .switchToSpace, .setStreamQuality,
             .refreshSpacePreviews:
            // Handled upstream in HostModel.onCommand before this method is called.
            break
        }
    }

    // MARK: - Teardown

    /// Releases everything the client left held, because the held state outlives the
    /// connection that created it.
    ///
    /// **This is not tidiness, and the failure it prevents is on the user's own machine.**
    /// A client that drops between a key's down and its up leaves the window server
    /// believing the modifier is still pressed, and nothing on this side will ever clear
    /// it: the release was going to come from the client that is gone. The Mac then sits
    /// with ⌘ held — every later keystroke, from the physical keyboard, in every
    /// application, is read as a shortcut — until a real key-up for that modifier happens
    /// to arrive. A dropped mouse-down is the same class of bug and nastier to notice: the
    /// button stays down, so the user's next physical click completes the *client's* drag.
    ///
    /// Called when the last client goes away rather than on every disconnect. The held
    /// state belongs to the Mac, not to a session — it cannot be attributed to one client —
    /// and releasing it while another client is still connected would drop a modifier that
    /// client is legitimately holding. With one client, which is the case this app is built
    /// for, "last client" and "the client" are the same thing.
    ///
    /// Deliberately **not** gated on Accessibility trust the way every other posting path
    /// here is. That gate exists to avoid emitting events into an application the user has
    /// not authorised; this is the one call whose entire purpose is to *undo* an event, and
    /// refusing it would leave the stuck state in place. It is also unreachable while
    /// untrusted — ``perform(_:)`` drops every command at the same gate, so nothing was
    /// ever held and the guard below returns before posting anything.
    func releaseAll() {
        let held = lock.withLock { () -> (buttons: [MouseButton], modifiers: Modifiers) in
            let snapshot = (buttons: heldButtons, modifiers: heldModifiers)
            heldButtons.removeAll()
            chordEngaged.removeAll()
            return snapshot
        }
        // Nothing to undo. Worth returning early rather than falling through: a flags change
        // with no change in it, or a mouse-up for a button that was never pressed, invents
        // input the client never asked for — and the mouse-up in particular is a real event
        // that a view under the cursor would act on.
        guard !held.buttons.isEmpty || !held.modifiers.isEmpty else { return }

        // Through `transition` rather than by posting a flags change directly, so each bit
        // is released along the same path a real chord uses: the state is cleared as part of
        // the release, and every flags change carries the state that actually results rather
        // than a guess at it. Reverse of the press order, as a keyboard releases.
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

    // MARK: - Event construction

    private func location(for point: NormalizedPoint) -> CGPoint? {
        guard let transform = lock.withLock({ _transform }) else {
            // No capture source yet, so there is no space to map into. Dropping the command
            // is right: guessing a display would send the cursor somewhere arbitrary, and
            // the cursor would visibly jump the moment capture started.
            return nil
        }
        return transform.globalPoint(fromNormalized: point)
    }

    private func postMouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            inputLog.error("could not create a \(String(describing: type), privacy: .public) event")
            return
        }
        event.post(tap: .cghidEventTap)
    }

    /// Posts a key, engaging and disengaging any modifiers around it.
    ///
    /// **The modifiers are posted as real key events, not merely as flag bits on the key
    /// itself.** This is the whole reason the method is shaped like this. Setting
    /// `CGEvent.flags` describes the modifier state *for that one event*; it does not
    /// release the modifier, and the window server goes on believing it is held. The
    /// symptom is quiet and severe: after `Cmd+V`, every later keystroke is read as a
    /// shortcut — injected text becomes `Cmd+X`, cut, and the document stops receiving
    /// characters entirely while every layer above reports success.
    ///
    /// So a chord is posted the way a keyboard posts one: modifiers down, the key, then
    /// modifiers up in reverse order.
    private func postKey(code: UInt16, down: Bool, modifiers: Modifiers) {
        if let bit = InputEncoding.modifierBit(for: code) {
            transition(bit, down: down)
            return
        }

        if InputEncoding.isModifierKeyCode(code) {
            // Caps lock and fn: reported as flags changes, but with no bit to track, so the
            // flags go out unchanged. Handled before the chord path because a modifier that
            // has no bit can never be part of one.
            postFlagsChange(code: code, flags: lock.withLock { heldModifiers })
            return
        }

        if down {
            var pressed: Modifiers = []
            for (bit, modifierCode) in Self.modifierKeys where modifiers.contains(bit) {
                if transition(bit, down: true, code: modifierCode) { pressed.insert(bit) }
            }
            lock.withLock { chordEngaged[code] = pressed }
        }

        postKeyEvent(code: code, down: down)

        if !down {
            let engaged = lock.withLock { chordEngaged.removeValue(forKey: code) } ?? []
            for (bit, modifierCode) in Self.modifierKeys.reversed() where engaged.contains(bit) {
                transition(bit, down: false, code: modifierCode)
            }
        }
    }

    private func postKeyEvent(code: UInt16, down: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(code),
            keyDown: down
        ) else {
            inputLog.error("could not create a keyboard event for keycode \(code)")
            return
        }

        // Set explicitly rather than left to inherit. An event built from a null source takes
        // whatever modifiers the system currently believes are held, so a chord posted just
        // before this would otherwise rewrite the keystroke into a shortcut.
        event.flags = cgFlags(lock.withLock { heldModifiers })
        event.post(tap: .cghidEventTap)
    }

    /// Applies a modifier transition and posts the flags change describing it.
    ///
    /// - Returns: whether it changed anything. A chord only releases the modifiers it
    ///   actually pressed, so a modifier the client had toggled on stays on.
    @discardableResult
    private func transition(_ bit: Modifiers, down: Bool, code: UInt16? = nil) -> Bool {
        let changed = lock.withLock { () -> Bool in
            if down {
                guard !heldModifiers.contains(bit) else { return false }
                heldModifiers.insert(bit)
            } else {
                guard heldModifiers.contains(bit) else { return false }
                heldModifiers.remove(bit)
            }
            return true
        }
        guard changed else { return false }

        let keyCode = code ?? Self.modifierKeys.first { $0.bit == bit }?.code
        guard let keyCode else { return true }
        postFlagsChange(code: keyCode, flags: lock.withLock { heldModifiers })
        return true
    }

    /// A flags change is how macOS reports a modifier moving: `virtualKey` names the key that
    /// moved, and the flags carry the resulting state.
    private func postFlagsChange(code: UInt16, flags: Modifiers) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(code),
            keyDown: true
        ) else {
            inputLog.error("could not create a flags change for keycode \(code)")
            return
        }
        event.type = .flagsChanged
        event.flags = cgFlags(flags)
        event.post(tap: .cghidEventTap)
    }

    private func cgFlags(_ modifiers: Modifiers) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(modifiers.rawValue))
    }

    private func postText(_ text: String) {
        for chunk in InputEncoding.unicodeChunks(text) {
            // A down/up pair per chunk, so the text arrives as ordinary typing rather than
            // as whatever a lone key-down would mean to the focused application.
            postUnicode(chunk, down: true)
            postUnicode(chunk, down: false)
        }
    }

    private func postUnicode(_ units: [UInt16], down: Bool) {
        // Keycode 0 is a placeholder: in Unicode mode the character comes from the string
        // attached below, not from the keycode, so the value is never consulted.
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
            return
        }
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        // Text is never modified. Left to inherit, this event would take the current modifier
        // state — so typing immediately after a shortcut would submit the text as a keyboard
        // command instead of inserting it.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private func mouseType(for button: MouseButton, pressed: Bool) -> CGEventType {
        switch (button, pressed) {
        case (.left, true): return .leftMouseDown
        case (.left, false): return .leftMouseUp
        case (.right, true): return .rightMouseDown
        case (.right, false): return .rightMouseUp
        case (.middle, true): return .otherMouseDown
        case (.middle, false): return .otherMouseUp
        }
    }

    private func cgButton(_ button: MouseButton) -> CGMouseButton {
        // The raw values are already the CGMouseButton ordering: left 0, right 1, other 2.
        CGMouseButton(rawValue: UInt32(button.rawValue)) ?? .left
    }

    /// Logged once, not per event. A client sending a stream of moves would otherwise write
    /// thousands of identical lines and bury whatever else the log had to say.
    private func warnUntrustedOnce() {
        let shouldWarn = lock.withLock { () -> Bool in
            guard !hasWarnedUntrusted else { return false }
            hasWarnedUntrusted = true
            return true
        }
        guard shouldWarn else { return }

        inputLog.fault("""
            Input was requested but this app is not trusted for Accessibility, so every \
            synthetic event is being discarded silently. Grant it in System Settings → \
            Privacy & Security → Accessibility, then relaunch — consent is read when the \
            process starts.
            """)
    }
}
