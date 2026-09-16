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
    /// Where the client last put the pointer, in the global space `CGEvent` posts into.
    ///
    /// Nothing writes it except a clamped position, which is what lets a click, a drag and a
    /// scroll-at-cursor reuse it without asking again whether it is somewhere the user can
    /// still see. The initial `.zero` is only ever read by a click that arrives before the
    /// client has moved the pointer at all.
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

    /// The window drag the client is in the middle of, if any.
    ///
    /// Present from the mouse-down that starts a command-drag until the mouse-up that ends
    /// it — including while the Accessibility lookup is still running and after it has come
    /// back with nothing. Both of those matter: the first is why a move that arrives in the
    /// meantime is not posted as a pointer move, and the second is why the mouse-up that
    /// ends it is not posted as a button release the client never pressed.
    private var windowMove: WindowMove?

    /// Bumped for every grab; see ``WindowMove/id``.
    private var nextWindowMoveID: UInt64 = 0

    /// A window the client has picked up with a command-drag, and where it was picked up.
    private struct WindowMove {
        /// What tells this grab apart from every other one. A session that ends mid-drag
        /// leaves a lookup and a position change queued behind it, and the drag after it
        /// must not be the thing they land on.
        let id: UInt64
        /// Where the pointer was at the grab, in the global space `cursor` is in. Every
        /// offset is measured from it, so the window travels exactly as far as the client's
        /// finger did and no further.
        let grab: CGPoint
        /// The window itself, once the lookup has landed. `nil` before it does, and `nil`
        /// for good when it came back empty; both mean there is nothing to move.
        var window: AXUIElement?
        /// The window's top-left at the grab. A window is positioned, not displaced — the
        /// window server has no delta form — so this is what the offset is added to.
        var origin: CGPoint = .zero
        /// Whether a refused position change has been logged for this grab. One that is
        /// refused is refused sixty times a second, and the log wants one line of that.
        var hasReportedFailure = false
    }

    /// Where the Accessibility work runs.
    ///
    /// **Not the queue this type is called on, which is the network one.** `perform` runs on
    /// the server's serial queue — the queue the control channel is read on, and in a
    /// relayed session the one video arrives on too — and an Accessibility call to an
    /// application that has stopped answering blocks until the API's own messaging timeout
    /// gives up on it. A window drag asks sixty times a second, so a single stuck target
    /// application would take the picture and the client's own control channel down with
    /// it. This queue absorbs that wait and nothing else notices it.
    ///
    /// Serial, because a window drag is a state machine spread across commands — the press
    /// that resolves the window, the moves that carry it, the release that ends it — and
    /// order is the only thing that makes each one see the state the last one left.
    private let windowMoveQueue = DispatchQueue(label: "pl.dmq.peering.host.input.window-move")

    /// The element every hit-test starts from. System-wide rather than per-application,
    /// because the point of the exercise is to find whatever is under the pointer, and that
    /// is whichever application happens to be in front of that pixel.
    private let systemWide = AXUIElementCreateSystemWide()

    /// How far up a parent chain a window is looked for before giving up.
    ///
    /// A window is a handful of levels above whatever was hit. The bound is here because the
    /// chain is read from another process a call at a time: a tree deeper than it should be
    /// is that many round trips on every grab, and a loop in one would be round trips that
    /// never come back.
    private static let maximumAncestorDepth = 32

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
            // Recorded even when the move itself is swallowed, and that is not a detail: the
            // client really has put the pointer there, and the click, drag or scroll that
            // comes next is posted at this position. Left behind at the grab, the first
            // click after a window drag would land where the window used to be.
            let moveID = lock.withLock { () -> UInt64? in
                cursor = location
                return windowMove?.id
            }
            guard let moveID else {
                postMouse(.mouseMoved, at: location, button: .left)
                return
            }
            // **Posted, and the window is carried as well.** The two do not fight: the window's
            // position is computed from ``cursor``, which is set above, and never from what was
            // posted — so posting it moves the pointer by the delta and ``applyWindowMove``
            // moves the window by the same delta, and the point of the window that was under
            // the finger at the grab stays under the finger. That is what an ordinary drag on
            // the Mac does, and it is what makes the gesture read as carrying something.
            //
            // Swallowing the move instead left the drawn pointer parked at the grab point
            // while the window slid out from under it — the overlay draws from the *live*
            // cursor, so it went on drawing the pointer where the drag started. It reads as
            // the window having come loose from the finger, which is the one thing a drag must
            // never look like.
            postMouse(.mouseMoved, at: location, button: .left)

            windowMoveQueue.async { [weak self] in
                self?.applyWindowMove(to: location, id: moveID)
            }

        case .mouseDown(let button):
            // Uses the position we last posted, not the live cursor. If the user nudges the
            // physical mouse between the client's move and its click, the live cursor is no
            // longer where the client is drawing it — and a click has to land where the
            // user is looking, which is the drawn position.
            let location = lock.withLock { cursor }

            // A command-drag is a window move, and it is the client's Move button that arms
            // it — it latches the same command bit the shortcuts panel's ⌘ does, so a
            // command held at the moment of the press is the whole of the test.
            //
            // Decided here and not re-decided later: a drag that began as a window move is
            // one until the button comes up, even if command is let go in between. The
            // modifier is how the gesture is recognised, not a condition it runs under, and
            // a drag abandoned halfway would leave the window wherever the finger was when
            // the bit changed.
            //
            // Nothing is posted and no button is recorded as held, and both are the point:
            // there is no click for the client to have meant, so the mouse-up that ends this
            // drag must not be a release for a press that never went out. See the mouse-up
            // case below.
            if button == .left, lock.withLock({ heldModifiers.contains(.command) }) {
                beginWindowMove(from: location)
            } else {
                lock.withLock { if !heldButtons.contains(button) { heldButtons.append(button) } }
                postMouse(mouseType(for: button, pressed: true), at: location, button: cgButton(button))
            }

        case .mouseUp(let button):
            let location = lock.withLock { cursor }
            lock.withLock { heldButtons.removeAll { $0 == button } }
            // The mouse-up that ends a window move posts nothing. No mouse-down went out
            // either, so this would be a release with no press behind it — a real event, and
            // one that whatever is under the cursor will act on. The window stays where the
            // last move put it, which is where the finger let go.
            if button == .left, endWindowMove() { return }
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
            // Placed at the position the client is drawing, for the reason the click path above
            // gives. An event built with no source carries no location of its own, so macOS
            // routes it to the *live* system cursor — and a wheel event goes to whatever is
            // under the pointer. Nudging the physical mouse between the client's last move and
            // its next scroll was therefore enough to scroll a different window than the one
            // the user was looking at, silently and with nothing on either screen to explain it.
            event.location = lock.withLock { cursor }
            event.post(tap: .cghidEventTap)

        case .keyDown(let keyCode, let modifiers):
            postKey(code: keyCode, down: true, modifiers: modifiers)

        case .keyUp(let keyCode, let modifiers):
            postKey(code: keyCode, down: false, modifiers: modifiers)

        case .textInput(let text):
            postText(text)

        case .lockScreen:
            // Control-Command-Q is macOS's documented Lock Screen shortcut. Sending it through
            // the same Accessibility-gated path as every other key keeps this command inside
            // the permission the user already granted, and never handles their Mac password.
            postKey(code: 12, down: true, modifiers: [.control, .command])
            postKey(code: 12, down: false, modifiers: [.control, .command])
            inputLog.notice("lock screen shortcut posted")

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
                // Clamped, and this is the path that most needs it: the origin is wherever the
                // physical mouse was left when the gesture started, which is routinely a place
                // the captured window is not, and a joystick reports a delta with no idea where
                // it is pushing to. Left unclamped the pointer walks off the shared content and
                // keeps walking, because the accumulated deltas never stop arriving.
                let target = clamped(CGPoint(x: origin.x + pdx, y: origin.y + pdy), to: _transform)
                cursor = target
                return target
            }

            if let target = postTarget {
                postMouse(.mouseMoved, at: target, button: .left)
            }

        case .setCaptureSource, .launchApplication, .switchToSpace, .setStreamQuality,
             .refreshSpacePreviews, .setPrivacyMode, .requestClipboard, .pushClipboard:
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
    ///
    /// A window move in progress is dropped here too, and the window is left where the last
    /// move put it rather than being put back. Putting it back would be a second change to a
    /// window the session is no longer entitled to touch, and the position it would restore
    /// is where the drag began, which is not where the user last asked for it. Dropped
    /// before the guard rather than after, because that guard returns early when nothing is
    /// held — and command can be let go before the drop, leaving a grab with no modifier
    /// left to release. Left set, it would swallow every pointer move of the next session.
    func releaseAll() {
        lock.withLock { windowMove = nil }
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

    // MARK: - Window moves

    /// Picks up the window under the pointer, in place of the click that would have gone out.
    ///
    /// **This is the Move button, and it exists because command-drag does not do the job.**
    /// macOS does move a window under a command-drag of its own, and that was the whole of
    /// the original design: the client latches command, drags as usual, and the window is
    /// supposed to follow. It does not. The modifier arrives as a real flags change and is
    /// genuinely held, and the window still does not move — what the user gets is a pointer
    /// that travels the entire gesture with nothing under it, which is indistinguishable
    /// from the feature being broken, because it is. So the window is moved here, by the API
    /// that exists for exactly this, and every step of it is checked rather than assumed.
    ///
    /// **A grab that finds nothing is not a click.** There is no fallback to posting the
    /// mouse-down the way an ordinary click would: the user has asked for a window to be
    /// carried, and a click that lands on whatever is under the pointer instead — a button,
    /// a link, a text field — does something they did not ask for and cannot see coming. The
    /// drag does nothing at all instead, which is what a command-drag across the desktop
    /// does on a Mac.
    ///
    /// The Accessibility permission this needs is the one ``perform(_:)`` already refuses to
    /// run without, so the gate at the top of it covers this path as well.
    private func beginWindowMove(from pointer: CGPoint) {
        let id = lock.withLock { () -> UInt64 in
            nextWindowMoveID += 1
            // Armed before the lookup is asked for, not after it answers. The moves that
            // follow are suppressed on the strength of this being set, and a move that
            // arrived first and was posted as an ordinary one would drag the pointer off the
            // window by exactly as far as it had travelled.
            windowMove = WindowMove(id: nextWindowMoveID, grab: pointer)
            return nextWindowMoveID
        }
        windowMoveQueue.async { [weak self] in self?.resolveWindowMove(id: id) }
    }

    /// Finds the window at the grab and remembers where it was.
    private func resolveWindowMove(id: UInt64) {
        // Read once, under the lock: the window is placed by the pointer the client had when
        // it pressed, not by the one it has by the time the lookup comes back.
        guard let grab = lock.withLock({ windowMove?.id == id ? windowMove?.grab : nil }) else { return }

        guard let window = windowElement(at: grab) else {
            // Nothing under the pointer. The grab stays armed until the button comes up and
            // moves nothing — no window, and no pointer either, for the reason the mouseMove
            // case gives. The command-drag is inert, which is the honest outcome.
            inputLog.notice("""
                no window under \(grab.x, privacy: .public),\(grab.y, privacy: .public), so \
                this command-drag moves nothing
                """)
            return
        }

        guard let origin = pointValue(kAXPositionAttribute, of: window) else {
            inputLog.notice("the window under the pointer reports no position, so it cannot be moved")
            return
        }

        // Asked once, before the drag, rather than inferred from it. A window that will not
        // accept a position is the one case where every single move of the gesture fails,
        // and one question here says so once instead of sixty silent failures a second.
        // Only a definite no stops the grab: a check that cannot be answered is not a
        // refusal, and treating one as a refusal would refuse a window that moves perfectly
        // well because the first call to its application timed out.
        var settable: DarwinBoolean = false
        let check = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
        if check == .success, !settable.boolValue {
            inputLog.error("the window under the pointer refuses a position change, so it will not move")
            return
        }

        lock.withLock {
            guard windowMove?.id == id else { return }
            windowMove?.window = window
            windowMove?.origin = origin
        }
    }

    /// Carries the window by however far the pointer has travelled since the grab.
    ///
    /// The offset is measured from the grab every time rather than accumulated into a
    /// running total, which is what makes a move that is delayed, coalesced or refused leave
    /// nothing behind: the next one puts the window where the pointer is now, not where a
    /// sum of past deltas believes it should be.
    private func applyWindowMove(to pointer: CGPoint, id: UInt64) {
        guard let move = lock.withLock({ windowMove?.id == id ? windowMove : nil }),
              let window = move.window else { return }

        var target = CGPoint(
            x: move.origin.x + (pointer.x - move.grab.x),
            y: move.origin.y + (pointer.y - move.grab.y)
        )

        // A bare `CGPoint`, because that is the space `cursor` is already in — the two
        // agree, and nothing here converts or flips anything.
        //
        // **Verified rather than assumed, because the failure it rules out is a window that
        // jumps a display height away from the pointer.** The header is explicit —
        // `kAXPositionAttribute` is a `CGPoint` in points whose 0,0 is the top-left corner of
        // the screen holding the menu bar, its y increasing downward — and the window server
        // was asked as well, on this machine. The attribute read back from real windows
        // agreed with `CGWindowListCopyWindowInfo` to the point, including a window sitting
        // at y 33 rather than at 0 (a y growing upward would have said 4), and setting it to
        // y + 90 moved the window down the screen by 90. So it is the same space
        // `CGEvent` posts into, and the same one `cursor` is stored in.
        guard let value = AXValueCreate(.cgPoint, &target) else { return }

        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard error != .success else { return }
        reportWindowMoveFailure(error, id: id)
    }

    /// Ends the window move, if one is in progress.
    ///
    /// - Returns: whether there was one. The caller posts nothing when there was, because
    ///   nothing was posted to begin with.
    @discardableResult
    private func endWindowMove() -> Bool {
        lock.withLock {
            guard windowMove != nil else { return false }
            windowMove = nil
            return true
        }
    }

    /// Logs a refused position change, once per grab. Sixty identical lines a second would
    /// bury everything else the log had to say, and the first one already says all of it.
    private func reportWindowMoveFailure(_ error: AXError, id: UInt64) {
        let isFirst = lock.withLock { () -> Bool in
            guard windowMove?.id == id, windowMove?.hasReportedFailure == false else { return false }
            windowMove?.hasReportedFailure = true
            return true
        }
        guard isFirst else { return }
        inputLog.error("""
            a window move was refused with \(error.rawValue, privacy: .public), so the window \
            is not following the pointer
            """)
    }

    /// The window under a point, or `nil` when there is not one.
    private func windowElement(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        // `kAXErrorNoValue` — nothing there at all — is an answer, not a fault, and it is
        // handled the same way as the rest: no window, so nothing to move.
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        ) == .success, let hit else { return nil }

        // Never this application's own windows, and this is not tidiness. The window a client
        // is moving is one it is looking at, never the one showing it the picture — and the
        // accessible route into our own process is a different one: the request is served
        // in-process, on a thread AppKit's window machinery does not expect it on, and that
        // was measured aborting the process rather than refused.
        var pid: pid_t = 0
        if AXUIElementGetPid(hit, &pid) == .success, pid == getpid() { return nil }

        // A hit lands on whatever is drawn at that pixel — the text area inside a terminal,
        // a button, the group inside a split view — so the element that has to move is an
        // ancestor of it and never the hit itself. `kAXWindowAttribute` is the direct answer
        // and anything inside a window has one, so it is asked first, and the walk below is
        // the fallback for the elements that have no window to name: a hit on the menu bar
        // answers with no value at all, which is the correct answer, because a menu bar is
        // in no window.
        if let window = elementValue(kAXWindowAttribute, of: hit) { return window }

        var node: AXUIElement? = hit
        var depth = 0
        while let current = node, depth < Self.maximumAncestorDepth {
            if stringValue(kAXRoleAttribute, of: current) == kAXWindowRole { return current }
            node = elementValue(kAXParentAttribute, of: current)
            depth += 1
        }
        return nil
    }

    /// The value of a point-valued attribute, or `nil` when the element does not answer with
    /// one — an element that has gone away since the hit-test, or one whose position is not
    /// the `CGPoint` its documentation promises. The type check is what makes the cast safe;
    /// `AXValueGetValue` is what makes a value of the wrong type a `nil` rather than a trap.
    ///
    /// The attribute is taken as a `String` and bridged here, so the call sites can name the
    /// constant as it is spelled rather than casting at each of them.
    private func pointValue(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// The value of an element-valued attribute, or `nil` when the element has none.
    private func elementValue(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // A bit cast rather than a downcast, because a `CFTypeRef` is not a class the runtime
        // will match for us. The type ID above is the check that makes it true.
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    /// The value of a string-valued attribute, or `nil` when the element has none.
    private func stringValue(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFStringGetTypeID() else { return nil }
        return ref as? String
    }

    // MARK: - Event construction

    private func location(for point: NormalizedPoint) -> CGPoint? {
        guard let transform = lock.withLock({ _transform }) else {
            // No capture source yet, so there is no space to map into. Dropping the command
            // is right: guessing a display would send the cursor somewhere arbitrary, and
            // the cursor would visibly jump the moment capture started.
            return nil
        }
        let location = transform.globalPoint(fromNormalized: point)
        // A NaN survives `min` and `max` — Swift propagates it rather than clamping it — so a
        // malformed coordinate would pass through the clamp below and reach `CGEvent`, which
        // puts the pointer somewhere no rectangle can describe and no user can find. Dropped
        // for the same reason a missing transform is: a command that cannot be placed is worse
        // than one that does not run. The joystick path needs no equivalent guard because it
        // already rejects non-finite deltas before it accumulates them.
        guard location.x.isFinite, location.y.isFinite else { return nil }
        return clamped(location, to: transform)
    }

    /// Holds a point inside whatever is being captured.
    ///
    /// **Without this the pointer can be sent somewhere the user cannot see or reach it.** The
    /// client's canvas is not the shared content: it overscrolls during a gesture and its own
    /// aspect ratio differs from the capture's, so a drag near an edge produces coordinates that
    /// land off the display — or, worse because nothing on screen marks that boundary, outside
    /// the window being shared and onto the desktop behind it. The client goes on drawing the
    /// cursor at the edge of its canvas while the real one sits in neither place.
    ///
    /// Applied where a position is *produced*, rather than inside ``postMouse(_:at:button:)``, so
    /// that every path moving the pointer inherits it: a click, a drag and a scroll-at-cursor all
    /// reuse the last posted position, and clamping here is what makes that stored position safe
    /// to reuse. Clamping again on the way *out* of a click would be the wrong place for it —
    /// that click is deliberately posted at the position the client drew, and if the captured
    /// window has moved since, a second clamp would pull the click to an edge the user never saw
    /// the pointer at.
    ///
    /// Saturating rather than refusing, which is the whole point of putting it here. A finger
    /// held past the boundary keeps producing out-of-range coordinates, and the pointer is meant
    /// to stop at the edge and stay there — dropping the command instead would leave it frozen
    /// short of the edge, and the correction that follows would then be measured from the wrong
    /// place.
    ///
    /// Silent by design. A saturated edge is the expected result of a finger held past the
    /// boundary, not a fault, and the client keeps sending the same out-of-range value for as
    /// long as the finger stays there — anything logged here would repeat at its frame rate and
    /// bury the log.
    ///
    /// - Parameter transform: The mapping in force, passed in rather than read here so the
    ///   callers already holding the lock can use this without taking it a second time. `nil`
    ///   leaves the point alone; so does a transform that describes no area.
    private func clamped(_ point: CGPoint, to transform: InputTransform?) -> CGPoint {
        guard let transform, let bounds = captureBounds(transform) else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// The rect the captured content covers, in the global point space `CGEvent` posts into.
    ///
    /// Nothing has to be asked of the capture side to get this, and it works for all three kinds
    /// of source from one expression: ``InputTransform`` is built *from* the content's own rect
    /// every time it is made — a display's `CGDisplayBounds`, an application's window union, a
    /// single window's frame, and for the two that move, the `screenRect` that travels with every
    /// frame precisely because a dragged window reports the change no other way. So a window
    /// capture clamps to that window and a display capture clamps to that display, and the
    /// per-frame path means the rect stays right as the window moves.
    ///
    /// `origin` is the rect's **top-left** and this space has y increasing *downward* — the same
    /// convention `CGEvent` posts in, and the one ``InputTransform/globalPoint(fromNormalized:)``
    /// already relies on — so the height is added downward from `origin.y`. Flipping that is
    /// invisible on a display whose origin is (0, 0) and wrong on every other one, which is what
    /// makes it worth stating rather than assuming.
    ///
    /// `nil` for a transform that describes no area, which is what a degenerate one is: a source
    /// that has gone away maps every coordinate to a single point, and that point must not be
    /// read as a one-point cell to hold the cursor inside. Leaving the point untouched is the
    /// honest answer there — the caller has already decided what a vanished source means.
    private func captureBounds(_ transform: InputTransform) -> CGRect? {
        // `pixelSize` is in pixels and `origin` is in points. Skipping this division is not a
        // near miss on a Retina panel: it describes a rect the size of the content *in pixels*,
        // which for anything smaller than a display is larger than the display itself.
        let scale = transform.pointPixelScale > 0 ? transform.pointPixelScale : 1
        let size = CGSize(
            width: transform.pixelSize.width / scale,
            height: transform.pixelSize.height / scale
        )
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: transform.origin, size: size)
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
        // Whatever the client has latched applies to the mouse as well as to the keyboard.
        //
        // A no-op for an ordinary click, and the whole of how a window is moved: macOS carries
        // a window under a command-drag without bringing it to the front, so arming command is
        // what turns a drag on the picture into "pick this window up" — from anywhere in it,
        // rather than from a title bar a few pixels wide on a phone.
        //
        // Set explicitly rather than left to the event source. The source is `hidSystemState`,
        // which reports what the *hardware* is doing, and a command key this app posted
        // synthetically is not hardware: without this the drag would reach the window server as
        // an ordinary one and nothing would move. `Modifiers`' raw values are the `CGEventFlags`
        // bits, which is why this is a reinterpretation rather than a mapping.
        //
        // Safe to take the lock here: every caller posts outside it.
        event.flags = CGEventFlags(rawValue: UInt64(lock.withLock { heldModifiers }.rawValue))
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
            Privacy & Security → Accessibility, then relaunch. Consent is read when the \
            process starts.
            """)
    }
}
