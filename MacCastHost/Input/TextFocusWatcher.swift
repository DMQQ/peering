import ApplicationServices
import Foundation
import RemoteCore

/// Reports each move of the Mac's keyboard focus, and whether it landed somewhere that takes typing.
///
/// Polled rather than observed: an `AXObserver` is per application and would have to be moved every
/// time the frontmost one changes, while one question to the system-wide element covers every app.
/// Runs only while a phone is connected.
nonisolated final class TextFocusWatcher: @unchecked Sendable {
    private var onChange: (@Sendable (TextFocus) -> Void)?
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

    func start(onChange: @escaping @Sendable (TextFocus) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            guard timer == nil else { return }
            needsBaseline = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastElement = nil
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
        case let (element?, last?) where CFEqual(element, last): return
        default: break
        }
        lastElement = element

        guard let element else {
            onChange?(TextFocus(isEditable: false))
            return
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success { exposeTree(of: pid) }
        onChange?(TextFocus(isEditable: Self.isEditable(element)))
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
