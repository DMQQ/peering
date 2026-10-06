import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RemoteCore
import os

private let inputLog = Logger(subsystem: "pl.dmq.peering.host", category: "input")

/// Every posting call is gated on Accessibility trust: without it CGEvent.post is a silent no-op, so a client connects and nothing happens.
/// The transform is behind a lock because it changes mid-session (source switch, window moved or resized).
final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var _transform: InputTransform?
    /// Only ever a clamped position, so clicks, drags and scroll-at-cursor can reuse it. The initial zero is read only by a click before any move.
    private var cursor: CGPoint = .zero

    var clickLocation: CGPoint { lock.withLock { cursor } }

    /// When the last joystick nudge arrived. See the `.joystickMove` case: it is what separates
    /// the first nudge of a gesture from the rest of one.
    private var lastJoystickAt: DispatchTime?
    private var lastJoystickPostedAt: DispatchTime?
    private var pendingJoystickDx: Double = 0
    private var pendingJoystickDy: Double = 0

    private static let joystickResyncGap: UInt64 = 250_000_000
    /// Nanoseconds between posted mouseMoved events (about 83 Hz): a burst guard sitting below the client's 60 Hz interval (16.7 ms), since a threshold at the interval makes jitter alternate small and double steps.
    private static let joystickPostInterval: UInt64 = 12_000_000

    // One shared source avoids allocating per event; hidSystemState reads modifier state correctly.
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var hasWarnedUntrusted = false

    /// Which modifiers the system believes are held; a modifier must be released explicitly (see postKey).
    private var heldModifiers: Modifiers = []

    /// Modifiers a chord pressed itself, so its key-up releases only those and not one the client toggled on.
    private var chordEngaged: [UInt16: Modifiers] = [:]

    /// Buttons pressed and not yet released, in press order. A lost mouse-up leaves a button down so the user's next physical click completes the client's drag; an array so release is in reverse press order.
    private var heldButtons: [MouseButton] = []

    /// From the mouse-down of a command-drag until the mouse-up, including while the AX lookup runs and after it returns nothing: moves meanwhile are not posted as pointer moves, and the mouse-up is not posted as a release.
    private var windowMove: WindowMove?

    private var nextWindowMoveID: UInt64 = 0

    private struct WindowMove {
        /// Tells grabs apart: a session ending mid-drag leaves queued work that must not land on the next drag.
        let id: UInt64
        /// Pointer position at the grab, in cursor space; offsets are measured from it.
        let grab: CGPoint
        /// nil before the lookup lands, and for good when it came back empty.
        var window: AXUIElement?
        /// The window is positioned, not displaced (no delta form), so offsets are added to this.
        var origin: CGPoint = .zero
        /// A refused position change is refused sixty times a second; log one line.
        var hasReportedFailure = false
    }

    /// Not the network queue: an Accessibility call to an unresponsive application blocks until the API timeout, and a window drag asks sixty times a second, which would stall the picture and control channel. Serial because a window drag is a state machine across commands.
    private let windowMoveQueue = DispatchQueue(label: "pl.dmq.peering.host.input.window-move")

    /// System-wide: the point is to find whatever is under the pointer in any application.
    private let systemWide = AXUIElementCreateSystemWide()

    /// Bounded because the chain is read from another process a call at a time; a loop would never return.
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

        case .setCaptureSource, .launchApplication, .switchToSpace, .setStreamQuality,
             .setVideoEnabled, .refreshSpacePreviews, .refreshSourceThumbnails, .watchSourceThumbnails,
             .setPrivacyMode, .requestClipboard, .pushClipboard, .pushClipboardImage, .reportDeviceOrientation,
             .addVirtualDisplay, .removeVirtualDisplay, .renameVirtualDisplay,
             .performWindowAction, .openNewWindow:
            // Handled upstream, in the host's own routing, before this method is called.
            break
        }
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

    // MARK: - Window moves

    /// The Move button exists because command-drag does not work: the modifier is genuinely held and the window still does not move. So the window is moved by the AX position API, every step checked.
    /// A grab that finds nothing is not a click: posting the mouse-down would do something the user did not ask for, so the drag does nothing at all.
    private func beginWindowMove(from pointer: CGPoint) {
        let id = lock.withLock { () -> UInt64 in
            nextWindowMoveID += 1
            // Armed before the lookup: moves that follow are suppressed on it, and one posted as ordinary would drag the pointer off the window.
            windowMove = WindowMove(id: nextWindowMoveID, grab: pointer)
            return nextWindowMoveID
        }
        windowMoveQueue.async { [weak self] in self?.resolveWindowMove(id: id) }
    }

    private func resolveWindowMove(id: UInt64) {
        // Read once under the lock: placed by the pointer at press, not the one when the lookup returns.
        guard let grab = lock.withLock({ windowMove?.id == id ? windowMove?.grab : nil }) else { return }

        guard let window = windowElement(at: grab) else {
            // Nothing under the pointer: the grab stays armed until the button comes up and moves nothing, so the command-drag is inert.
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

        // Asked once before the drag: an unsettable window fails every move, so one question beats sixty silent failures a second. Only a definite no stops the grab; a timed-out check is not a refusal.
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

    /// Measured from the grab each time, not accumulated, so a delayed, coalesced or refused move leaves nothing behind.
    private func applyWindowMove(to pointer: CGPoint, id: UInt64) {
        guard let move = lock.withLock({ windowMove?.id == id ? windowMove : nil }),
              let window = move.window else { return }

        var target = CGPoint(
            x: move.origin.x + (pointer.x - move.grab.x),
            y: move.origin.y + (pointer.y - move.grab.y)
        )

        // A bare CGPoint in the space cursor is in. Verified: kAXPositionAttribute is points with 0,0 at the top-left of the menu bar screen, y down, matching CGWindowListCopyWindowInfo (a window at y 33 read 33, and y + 90 moved it down 90); a window would otherwise jump a display height from the pointer.
        guard let value = AXValueCreate(.cgPoint, &target) else { return }

        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard error != .success else { return }
        reportWindowMoveFailure(error, id: id)
    }

    /// Returns whether there was one; the caller posts nothing then, since nothing was posted to begin with.
    @discardableResult
    private func endWindowMove() -> Bool {
        lock.withLock {
            guard windowMove != nil else { return false }
            windowMove = nil
            return true
        }
    }

    /// Once per grab: sixty identical lines a second would bury the log.
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

    private func windowElement(at point: CGPoint) -> AXUIElement? {
        // Window list before the hit test, which fixes a crash: a hit test over one of our own windows is served in-process on this queue and runs AppKit and SwiftUI accessibility off the main thread, tripping SwiftUI's main-thread assertion. The pid check below runs too late. A window list is Core Graphics and safe anywhere.
        if ownsWindow(at: point) { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        ) == .success, let hit else { return nil }

        // Kept as well as the check above: this reads the element the system resolved, covering an owner that changed between the calls.
        var pid: pid_t = 0
        if AXUIElementGetPid(hit, &pid) == .success, pid == getpid() { return nil }

        // A hit lands on whatever is drawn there, so the element to move is an ancestor: kAXWindowAttribute first, then the walk below for elements with no window (the menu bar answers no value, correctly).
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

    /// Read from the window server, not AppKit: NSWindow is main-thread state and this runs on the window-move queue. The first window containing the point decides, so only windows near the drag matter.
    private func ownsWindow(at point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let me = getpid()
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            if rect.contains(point) { return true }
        }
        return false
    }

    /// nil when the element does not answer with a CGPoint (gone since the hit test, or the wrong type); AXValueGetValue makes the wrong type a nil rather than a trap.
    private func pointValue(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func elementValue(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private func stringValue(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFStringGetTypeID() else { return nil }
        return ref as? String
    }

    // MARK: - Event construction

    private func location(for point: NormalizedPoint) -> CGPoint? {
        guard let transform = lock.withLock({ _transform }) else {
            // No capture source yet: dropping the command beats guessing a display, which would make the cursor jump when capture starts.
            return nil
        }
        let location = transform.globalPoint(fromNormalized: point)
        // NaN survives min and max, so a malformed coordinate would reach CGEvent and put the pointer somewhere no user can find. The joystick path rejects non-finite deltas earlier.
        guard location.x.isFinite, location.y.isFinite else { return nil }
        return clamped(location, to: transform)
    }

    /// Without this the pointer can be sent where the user cannot see it: the client canvas overscrolls and has its own aspect ratio, so a drag near an edge lands off the display or outside the shared window onto the desktop behind.
    /// Applied where a position is produced, not in postMouse, so every path inherits it and the stored position is safe to reuse; clamping again on a click would pull it to an edge the user never saw.
    /// Saturating, not refusing: a finger held past the boundary should stop the pointer at the edge, and dropping would freeze it short. Silent, since the client repeats the out-of-range value at frame rate.
    /// - Parameter transform: passed in so callers already holding the lock need not retake it. nil leaves the point alone, as does a transform with no area.
    private func clamped(_ point: CGPoint, to transform: InputTransform?) -> CGPoint {
        guard let transform, let bounds = captureBounds(transform) else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// InputTransform is built from the content's own rect (display bounds, application window union, or the per-frame screenRect that tracks a dragged window), so one expression serves every source kind.
    /// origin is the top-left with y increasing downward, as CGEvent posts; flipping is invisible on a display at (0, 0) and wrong on every other.
    /// nil for a transform with no area: a vanished source maps every coordinate to one point, which must not become a one-point cell holding the cursor.
    private func captureBounds(_ transform: InputTransform) -> CGRect? {
        // pixelSize is pixels and origin is points; skipping this division on Retina yields a rect larger than the display.
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
        // Whatever the client has latched applies to the mouse too. This is how a window is moved: arming command turns a drag on the picture into picking the window up from anywhere in it. Set explicitly because hidSystemState reports hardware, and a synthetic command key is not hardware; Modifiers raw values are the CGEventFlags bits. Safe to lock: every caller posts outside it.
        event.flags = CGEventFlags(rawValue: UInt64(lock.withLock { heldModifiers }.rawValue))
        event.post(tap: .cghidEventTap)
    }

    /// Modifiers are posted as real key events, not flag bits: flags describe state for one event and never release the modifier, so after Cmd+V every later keystroke reads as a shortcut and the document stops receiving characters while everything reports success. A chord goes modifiers down, the key, modifiers up in reverse.
    private func postKey(code: UInt16, down: Bool, modifiers: Modifiers) {
        if let bit = InputEncoding.modifierBit(for: code) {
            transition(bit, down: down)
            return
        }

        if InputEncoding.isModifierKeyCode(code) {
            // Caps lock and fn have no bit to track, so flags go out unchanged; handled before the chord path.
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

    private func postMediaKey(_ key: MediaKey) {
        switch key {
        case .missionControl:
            // Launched rather than keyed: the window server swallows an injected Mission Control
            // key the way it swallows the Spaces chord.
            let app = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        case .spotlight:
            postKey(code: 49, down: true, modifiers: [.command])
            postKey(code: 49, down: false, modifiers: [.command])
        case .brightnessDown: postAuxiliaryKey(3)
        case .brightnessUp: postAuxiliaryKey(2)
        case .rewind: postAuxiliaryKey(20)
        case .playPause: postAuxiliaryKey(16)
        case .fastForward: postAuxiliaryKey(19)
        case .mute: postAuxiliaryKey(7)
        case .volumeDown: postAuxiliaryKey(1)
        case .volumeUp: postAuxiliaryKey(0)
        }
    }

    /// An NX_KEYTYPE_* key, sent by keyboards as a system-defined event (subtype 8) not a key code.
    private func postAuxiliaryKey(_ type: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (type << 16) | (state << 8),
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
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

        // Set explicitly: a null-source event inherits the modifiers the system believes are held, so a chord posted just before would turn the keystroke into a shortcut.
        var flags = cgFlags(lock.withLock { heldModifiers })
        if Self.functionKeyCodes.contains(code) { flags.insert(.maskSecondaryFn) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static let functionKeyCodes = Set(MediaKey.functionKeyCodes)

    /// Returns whether it changed anything: a chord releases only what it pressed.
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
            postUnicode(chunk, down: true)
            postUnicode(chunk, down: false)
        }
    }

    private func postUnicode(_ units: [UInt16], down: Bool) {
        // Keycode 0 is a placeholder: in Unicode mode the character comes from the attached string.
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
            return
        }
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        // Text is never modified: inheriting the current modifier state would submit typing right after a shortcut as a keyboard command.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    /// A movement posted as .mouseMoved while a button is down is not a drag: apps match on event type, so mouseDragged: never runs and nothing is selected or dragged.
    /// The button comes from heldButtons so type and button agree: the window server matches a .leftMouseDragged against the press it tracks.
    private func moveType(holding button: MouseButton?) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        case nil: return .mouseMoved
        }
    }

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

    /// Once, not per event: a stream of moves would bury the log.
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
