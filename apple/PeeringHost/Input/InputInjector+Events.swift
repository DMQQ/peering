import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RemoteCore
import os

extension InputInjector {
    func location(for point: NormalizedPoint) -> CGPoint? {
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
    func clamped(_ point: CGPoint, to transform: InputTransform?) -> CGPoint {
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

    func postMouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton) {
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
    func postKey(code: UInt16, down: Bool, modifiers: Modifiers) {
        if let bit = InputEncoding.modifierBit(for: code) {
            transition(bit, down: down)
            return
        }

        if InputEncoding.isModifierKeyCode(code) {
            // Caps lock and fn have no bit to track, so flags go out unchanged; handled before the chord path.
            postFlagsChange(code: code, flags: lock.withLock { heldModifiers })
            return
        }

        if down, Self.submitKeyCodes.contains(code) { separateSubmitFromTypedText() }

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

    func postMediaKey(_ key: MediaKey) {
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
    func transition(_ bit: Modifiers, down: Bool, code: UInt16? = nil) -> Bool {
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

    /// Return and keypad Enter.
    private static let submitKeyCodes: Set<UInt16> = [36, 76]
    /// A terminal that reads typed text and Return in one gulp takes the Return for part of a paste: a line editor such as Claude Code's then inserts a newline and the sent text stays in the box.
    private static let submitSeparation: Duration = .milliseconds(45)

    private func separateSubmitFromTypedText() {
        let typedAt = lock.withLock { lastTextPostedAt }
        guard let typedAt else { return }
        let wait = Self.submitSeparation - typedAt.duration(to: .now)
        if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.attoseconds) / 1e18 + Double(wait.components.seconds)) }
    }

    func postText(_ text: String) {
        lock.withLock { lastTextPostedAt = .now }
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

    /// A movement posted as .mouseMoved while a button is down is not a drag: apps match on event type, so mouseDragged: never runs and nothing is selected or dragged.
    /// The button comes from heldButtons so type and button agree: the window server matches a .leftMouseDragged against the press it tracks.
    func moveType(holding button: MouseButton?) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        case nil: return .mouseMoved
        }
    }

    func mouseType(for button: MouseButton, pressed: Bool) -> CGEventType {
        switch (button, pressed) {
        case (.left, true): return .leftMouseDown
        case (.left, false): return .leftMouseUp
        case (.right, true): return .rightMouseDown
        case (.right, false): return .rightMouseUp
        case (.middle, true): return .otherMouseDown
        case (.middle, false): return .otherMouseUp
        }
    }

    func cgButton(_ button: MouseButton) -> CGMouseButton {
        // The raw values are already the CGMouseButton ordering: left 0, right 1, other 2.
        CGMouseButton(rawValue: UInt32(button.rawValue)) ?? .left
    }

    /// Once, not per event: a stream of moves would bury the log.
    func warnUntrustedOnce() {
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
