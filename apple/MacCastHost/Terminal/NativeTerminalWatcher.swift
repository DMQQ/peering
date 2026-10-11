import AppKit
import ApplicationServices
import Foundation
import RemoteCore
import os

private let nativeTermLog = Logger(subsystem: "pl.dmq.peering.host", category: "native-terminal")

let watchedBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "dev.warp.Warp",
    "co.zeit.hyper",
    "net.kovidgoyal.kitty",
]

final class NativeTerminalWatcher: @unchecked Sendable {
    var onAttention: (@Sendable (String, CGWindowID?) -> Void)?

    private let lock = NSLock()
    private var appWatches: [pid_t: TerminalAppWatch] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                watchedBundleIDs.contains(app.bundleIdentifier ?? "")
            else { return }
            self?.attach(app)
        }
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.detach(pid: app.processIdentifier)
        }
        lock.withLock { workspaceObservers = [launched, terminated] }

        for app in NSWorkspace.shared.runningApplications
            where watchedBundleIDs.contains(app.bundleIdentifier ?? "") {
            attach(app)
        }
    }

    func stop() {
        let (observers, watches) = lock.withLock { () -> ([NSObjectProtocol], [TerminalAppWatch]) in
            let o = workspaceObservers
            let w = Array(appWatches.values)
            workspaceObservers = []
            appWatches = [:]
            return (o, w)
        }
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        for w in watches { w.stop() }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let name = app.localizedName ?? "Terminal"
        let watch = TerminalAppWatch(pid: pid, appName: name) { [weak self] message, windowID in
            self?.onAttention?(message, windowID)
        }
        lock.withLock { appWatches[pid] = watch }
        watch.start()
    }

    private func detach(pid: pid_t) {
        lock.withLock { appWatches.removeValue(forKey: pid) }?.stop()
    }
}

// MARK: -

/// Watches one running terminal process via AXObserver.
private final class TerminalAppWatch: @unchecked Sendable {
    let pid: pid_t
    let appName: String
    let onAttention: @Sendable (String, CGWindowID?) -> Void

    private var axObserver: AXObserver?
    private var selfPtr: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var awaiting: Set<CFHashCode> = []
    private var pending: [CFHashCode: DispatchWorkItem] = [:]

    private static let queue = DispatchQueue(
        label: "pl.dmq.peering.host.native-term",
        qos: .utility
    )

    init(pid: pid_t, appName: String, onAttention: @escaping @Sendable (String, CGWindowID?) -> Void) {
        self.pid = pid
        self.appName = appName
        self.onAttention = onAttention
    }

    func start() {
        let retained = Unmanaged.passRetained(self).toOpaque()
        selfPtr = retained

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, element, notification, refcon in
            // @Sendable, no actor inference: required for @convention(c) callbacks.
            guard let refcon else { return }
            Unmanaged<TerminalAppWatch>.fromOpaque(refcon).takeUnretainedValue()
                .received(notification: notification, on: element)
        }, &obs)

        guard err == .success, let obs else {
            nativeTermLog.error("AXObserverCreate failed for \(self.appName, privacy: .public): \(err.rawValue)")
            Unmanaged<TerminalAppWatch>.fromOpaque(retained).release()
            selfPtr = nil
            return
        }
        axObserver = obs

        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, retained)
        AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString, retained)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        registerWindows(of: appElement, in: obs, refcon: retained)
        nativeTermLog.notice("watching \(self.appName, privacy: .public) pid \(self.pid)")
    }

    func stop() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        if let ptr = selfPtr {
            Unmanaged<TerminalAppWatch>.fromOpaque(ptr).release()
            selfPtr = nil
        }
        lock.withLock {
            pending.values.forEach { $0.cancel() }
            pending = [:]
        }
        nativeTermLog.notice("stopped watching \(self.appName, privacy: .public)")
    }

    // MARK: - AX notification dispatch

    private func received(notification: CFString, on element: AXUIElement) {
        let note = notification as String
        switch note {
        case kAXWindowCreatedNotification:
            if let obs = axObserver, let ptr = selfPtr {
                registerTextAreas(in: element, observer: obs, refcon: ptr)
            }
        case kAXFocusedUIElementChangedNotification:
            if let obs = axObserver, let ptr = selfPtr {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                   roleRef as? String == kAXTextAreaRole {
                    AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, ptr)
                }
            }
        case kAXValueChangedNotification:
            textAreaChanged(element)
        default:
            break
        }
    }

    // MARK: - Registration helpers

    private func registerWindows(of appElement: AXUIElement, in observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        for window in windows {
            registerTextAreas(in: window, observer: observer, refcon: refcon)
        }
    }

    /// Traverses the AX tree depth-first looking for text areas, registering each one found.
    private func registerTextAreas(in element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer, depth: Int = 0) {
        guard depth < 8 else { return }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return }

        if role == kAXTextAreaRole {
            AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
            return
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            registerTextAreas(in: child, observer: observer, refcon: refcon, depth: depth + 1)
        }
    }

    // MARK: - Detection

    private func textAreaChanged(_ element: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let text = ref as? String, !text.isEmpty else { return }
        let tail = String(text.suffix(4_096))
        let key = CFHash(element)
        schedule(text: tail, title: Self.windowTitle(of: element), windowID: Self.windowID(of: element), key: key)
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(windowRef as! AXUIElement, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// What the window this text area lives in is called.
    private static func windowTitle(of element: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success,
            let title = shortName(ofWindow: titleRef as? String)
        else { return nil }
        return title
    }

    /// The window's title without the emulator's own tail.
    private static func shortName(ofWindow title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let gridTail = #"\s*[—–-]\s*\d+\s*[×x]\s*\d+\s*$"#
        guard let tail = title.range(of: gridTail, options: .regularExpression) else { return title }
        let name = String(title[title.startIndex..<tail.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func schedule(text: String, title: String?, windowID: CGWindowID?, key: CFHashCode) {
        lock.withLock {
            pending[key]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.check(text: text, title: title, windowID: windowID, key: key)
            }
            pending[key] = item
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: item)
        }
    }

    private func check(text: String, title: String?, windowID: CGWindowID?, key: CFHashCode) {
        // One alert per prompt, and the re-arm is the half that matters: the scan asks whether the
        // text ends in a question, and a program that repaints while it waits no longer ends in
        // anything, so keying on the text alone means a push per repaint. A terminal watched from
        // outside never tells us the user answered, so the latch re-arms when the question stops
        guard let kind = TerminalAttentionDetector.scan(text) else {
            lock.withLock { _ = awaiting.remove(key) }
            return
        }
        guard lock.withLock({ awaiting.insert(key).inserted }) else { return }

        let noun = kind == .password ? "a password" : "confirmation"
        // The banner quotes the question alone: "[sudo] password for damian:" or Claude's "Do you
        // want to proceed?" says what is being asked, and a window name in front of it only pushed
        // that out of the line. The sentence, with the window, is the fallback for a question that
        // cannot be read.
        let who = title.map { "\(appName) \u{201C}\($0)\u{201D}" } ?? appName
        let message = TerminalAttentionDetector.question(inPlainText: text)
            ?? "\(who) is waiting for \(noun)."
        nativeTermLog.notice("\(message as String, privacy: .public)")
        onAttention(message, windowID)
    }
}

/// Maps an Accessibility window to its window server ID. Private, and used by every window
/// manager on the Mac for want of a public equivalent; the host ships outside the App Store.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
