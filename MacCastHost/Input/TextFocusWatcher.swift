import ApplicationServices
import Foundation
import RemoteCore
import os

private let focusLog = Logger(subsystem: "pl.dmq.peering.host", category: "focus")

/// Reports each move of the Mac's keyboard focus, and whether it landed somewhere that takes typing.
///
/// Polled rather than observed: an `AXObserver` is per application and would have to be moved every
/// time the frontmost one changes, while one question to the system-wide element covers every app.
/// Runs only while a phone is connected.
nonisolated final class TextFocusWatcher: @unchecked Sendable {
    private var onChange: (@Sendable (TextFocus) -> Void)?
    private var onField: (@Sendable (FieldState) -> Void)?
    private var transform: (@Sendable () -> InputTransform?)?
    /// The last state sent, so a tick that finds nothing new sends nothing.
    private var lastField: FieldState?
    /// Past this a field is a document, and sending it whole every time it changes is the wrong trade.
    private static let longestReadableText = 8000
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.text-focus", qos: .utility)
    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: DispatchSourceTimer?
    private var lastElement: AXUIElement?
    /// Set on start, so where focus already is when a phone connects is recorded rather than sent:
    /// only a move the user makes should open the phone's keyboard.
    private var needsBaseline = true
    /// Applications already asked to expose their accessibility tree. See ``exposeTree(of:)``.
    private var exposed: Set<pid_t> = []

    init() {
        // A hung application would otherwise hold each poll for the system's default of 6 seconds.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    func start(
        transform: @escaping @Sendable () -> InputTransform?,
        onChange: @escaping @Sendable (TextFocus) -> Void,
        onField: @escaping @Sendable (FieldState) -> Void
    ) {
        queue.async { [self] in
            self.onChange = onChange
            self.onField = onField
            self.transform = transform
            lastField = nil
            guard timer == nil else { return }
            needsBaseline = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Tells the client whether a click landed in something editable, even when focus did not move:
    /// a tap back into the focused field, or a click on empty space that leaves the field focused.
    func clicked(at location: CGPoint) {
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
            guard timer != nil, AXIsProcessTrusted() else { return }
            var hit: AXUIElement?
            let found = AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &hit)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success {
                lastElement = focused.map { $0 as! AXUIElement }
            }
            let editable = if found == .success, let hit {
                Self.isEditable(hit)
            } else {
                lastElement.map(Self.isEditable) ?? false
            }
            focusLog.debug("click · editable \(editable)")
            onChange?(TextFocus(isEditable: editable))
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastElement = nil
            lastField = nil
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        let element = result == .success ? value.map { $0 as! AXUIElement } : nil

        if needsBaseline {
            needsBaseline = false
            lastElement = element
            return
        }
        switch (element, lastElement) {
        case (nil, nil): return
        case let (element?, last?) where CFEqual(element, last):
            pollField(element)
            return
        default: break
        }
        lastElement = element
        lastField = nil

        guard let element else {
            onChange?(TextFocus(isEditable: false))
            return
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success { exposeTree(of: pid) }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let editable = Self.isEditable(element)
        focusLog.debug("focus moved · \(role as? String ?? "no role", privacy: .public) · editable \(editable)")
        onChange?(TextFocus(isEditable: editable))
        if editable { pollField(element) }
    }

    /// Reads the focused field's text, selection and caret, and sends them if any of the three moved.
    private func pollField(_ element: AXUIElement) {
        guard onField != nil, Self.isEditable(element) else { return }
        AXUIElementSetMessagingTimeout(element, 0.25)

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let isSecure = (subrole as? String) == "AXSecureTextField"

        var text: String?
        if !isSecure {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let string = value as? String,
               string.utf16.count <= Self.longestReadableText {
                text = string
            }
        }

        var selection = CFRange(location: 0, length: 0)
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection)
        } else if let text {
            selection = CFRange(location: text.utf16.count, length: 0)
        }

        let state = FieldState(
            text: text,
            selectionLocation: selection.location,
            selectionLength: selection.length,
            caret: isSecure ? nil : caretPoint(of: element, selection: selection)
        )
        guard state != lastField else { return }
        lastField = state
        onField?(state)
    }

    /// The middle of the insertion point's line, in the picture's normalized space.
    ///
    /// Asked of the caret's own range first, then of the character before it, because an empty range at
    /// the end of a line has no bounds in many applications. The whole element is the last resort, and a
    /// coarse one: for a tall text area it is the middle of the area rather than the line being typed.
    private func caretPoint(of element: AXUIElement, selection: CFRange) -> NormalizedPoint? {
        guard let transform = transform?() else { return nil }
        var candidates = [selection]
        if selection.length == 0, selection.location > 0 {
            candidates.append(CFRange(location: selection.location - 1, length: 1))
        }
        var rect: CGRect?
        for var range in candidates {
            guard let ranged = AXValueCreate(.cfRange, &range) else { continue }
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, ranged, &bounds
            ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var found = CGRect.zero
                AXValueGetValue(bounds as! AXValue, .cgRect, &found)
                if found.height > 0 { rect = found; break }
            }
        }
        if rect == nil {
            var frame: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frame) == .success,
               let frame, CFGetTypeID(frame) == AXValueGetTypeID() {
                var found = CGRect.zero
                AXValueGetValue(frame as! AXValue, .cgRect, &found)
                if found.height > 0 { rect = found }
            }
        }
        guard let rect else { return nil }
        let point = transform.normalizedPoint(fromGlobal: CGPoint(x: rect.midX, y: rect.midY))
        return (0...1).contains(point.x) && (0...1).contains(point.y) ? point : nil
    }

    /// Chromium and Electron apps build their accessibility tree only for assistive software, so
    /// their text fields are invisible here until asked. `AXManualAccessibility` is the switch they
    /// honour without the side effects of `AXEnhancedUserInterface`; other apps ignore it.
    private func exposeTree(of pid: pid_t) {
        guard exposed.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return true
        }
        // Editable web content (a `contenteditable` element, a rich editor) keeps its own role and
        // names the editable element it sits inside.
        var ancestor: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ancestor) == .success
            && ancestor != nil
    }
}
