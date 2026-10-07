import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RemoteCore
import os

extension InputInjector {
    struct WindowMove {
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

    /// The Move button exists because command-drag does not work: the modifier is genuinely held and the window still does not move. So the window is moved by the AX position API, every step checked.
    /// A grab that finds nothing is not a click: posting the mouse-down would do something the user did not ask for, so the drag does nothing at all.
    func beginWindowMove(from pointer: CGPoint) {
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
    func applyWindowMove(to pointer: CGPoint, id: UInt64) {
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
    func endWindowMove() -> Bool {
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
}
