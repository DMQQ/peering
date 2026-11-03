import AppKit
import ApplicationServices
import RemoteCore

extension HostModel {
    private static func windowNotFound(for action: WindowAction) -> LocalizedStringResource {
        switch action {
        case .close: "Could not find that window to close"
        case .minimize: "Could not find that window to minimize"
        case .zoom: "Could not find that window to zoom"
        }
    }

    private static func windowButtonMissing(for action: WindowAction) -> LocalizedStringResource {
        switch action {
        case .close: "That window has no close button"
        case .minimize: "That window has no minimize button"
        case .zoom: "That window has no zoom button"
        }
    }

    /// Presses a window's close, minimise or zoom button, then refreshes the catalogue so the
    /// phone's list follows.
    func performWindowAction(_ action: WindowAction, windowID: CGWindowID) {
        guard let pid = Self.owningProcess(of: .window(windowID)),
              let window = Self.accessibilityWindow(windowID, ofProcess: pid)
        else {
            record(Self.windowNotFound(for: action), level: .failure)
            return
        }
        let buttonAttribute = switch action {
        case .close: kAXCloseButtonAttribute
        case .minimize: kAXMinimizeButtonAttribute
        case .zoom: kAXZoomButtonAttribute
        }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, buttonAttribute as CFString, &ref) == .success,
           let button = ref, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        } else if action == .minimize {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        } else {
            record(Self.windowButtonMissing(for: action), level: .failure)
            return
        }
        Task { @MainActor [weak self] in
            // The window takes a moment to animate away before the window server stops listing it.
            try? await Task.sleep(for: .milliseconds(400))
            self?.coordinator?.refreshWindowList()
        }
    }

    /// The menu rather than a shortcut: Cmd-N in Zed is a new file. Cmd-N is the fallback for an app with no such item.
    func openNewWindow(bundleIdentifier: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.activationPolicy == .regular })
        else {
            launchApplication(bundleIdentifier: bundleIdentifier)
            return
        }
        bringToFront(running)
        let pid = running.processIdentifier
        let before = Set(Self.windowIDs(ofProcess: pid))
        Task { @MainActor [weak self] in
            // Keys posted before the application is frontmost go to whatever was.
            try? await Task.sleep(for: .milliseconds(250))
            if !Self.pressNewWindowMenuItem(ofProcess: pid) {
                Self.postCommandN(to: pid)
            }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if let fresh = Self.windowIDs(ofProcess: pid).first(where: { !before.contains($0) }) {
                    self.coordinator?.refreshWindowList()
                    self.pendingCaptureSource = .window(fresh)
                    self.applyCaptureSource(.window(fresh))
                    // Once more after it has settled: a window that has just appeared can still
                    // be missing its title and picture on the first pass.
                    try? await Task.sleep(for: .seconds(1))
                    self.coordinator?.refreshWindowList()
                    return
                }
            }
            self?.coordinator?.refreshWindowList()
        }
    }

    private static func pressNewWindowMenuItem(ofProcess pid: pid_t) -> Bool {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
            else { return [] }
            return ref as? [AXUIElement] ?? []
        }
        func title(_ element: AXUIElement) -> String {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
            return ref as? String ?? ""
        }
        func enabled(_ element: AXUIElement) -> Bool {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref)
            return (ref as? Bool) ?? true
        }

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &ref
        ) == .success, let bar = ref, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return false }

        for topItem in children(bar as! AXUIElement) {
            for menu in children(topItem) {
                for item in children(menu) where title(item).hasPrefix("New Window") && enabled(item) {
                    // An item with a submenu (Terminal's profiles) is pressed through its first entry.
                    if let submenu = children(item).first,
                       let first = children(submenu).first(where: enabled) {
                        return AXUIElementPerformAction(first, kAXPressAction as CFString) == .success
                    }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func postCommandN(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyN: CGKeyCode = 45
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: down)
            else { continue }
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }

    private static func windowIDs(ofProcess pid: pid_t) -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0
            else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }
        return CGRect(
            x: bounds["X"] ?? 0,
            y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0,
            height: bounds["Height"] ?? 0
        )
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
