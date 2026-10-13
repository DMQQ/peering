import AppKit
import ApplicationServices
import RemoteCore

// MARK: - Launching and raising applications

extension HostModel {
    /// SCK composites the windows of an application wherever they are, but input hits whatever is genuinely at those coordinates, so the app is raised first.
    /// .activateAllWindows because InputTransform is the union of every window. Moves the app in front of the Mac user, and switches Spaces if needed.
    func raiseSource(for source: CaptureSource) {
        guard let pid = Self.owningProcess(of: source),
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        bringToFront(running)

        // Then that window in particular: activating the app does not choose between its windows, and does nothing for an app already in front.
        if case .window(let id) = source {
            // Retried over the next second: a window just created has no final frame yet, and the first window of a launch does not exist when the switch returns.
            if !focusWindow(id, ofProcess: pid) {
                Task { @MainActor [weak self] in
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(220))
                        guard let self, capturingSource == source else { return }
                        if focusWindow(id, ofProcess: pid) { return }
                    }
                }
            }
        }
    }

    /// Found by frame: the AX window identifier is not the window server CGWindowID, but both agree on the frame (points, top-left origin).
    @discardableResult
    private func focusWindow(_ windowID: CGWindowID, ofProcess pid: pid_t) -> Bool {
        guard let window = Self.accessibilityWindow(windowID, ofProcess: pid) else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, window
        )
        return true
    }

    private static func accessibilityWindow(_ windowID: CGWindowID, ofProcess pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard let target = Self.windowFrame(windowID),
              AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement]
        else { return nil }

        // By frame, falling back to name: a window not yet placed is at its creation frame.
        let byFrame = elements.first { element in
            guard let frame = Self.frame(of: element) else { return false }
            // Half a point of slack: neither API rounds a window's edges the same way, and the same
            // window read twice is otherwise two different rectangles.
            return abs(frame.minX - target.minX) < 0.5
                && abs(frame.minY - target.minY) < 0.5
                && abs(frame.width - target.width) < 0.5
                && abs(frame.height - target.height) < 0.5
        }
        let title = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?
            .first?[kCGWindowName as String] as? String
        let byName = title.flatMap { name -> AXUIElement? in
            guard !name.isEmpty else { return nil }
            let matches = elements.filter { element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                        == .success
                else { return false }
                return (value as? String) == name
            }
            // Only when it is unambiguous: two windows with the same name are two windows this
            // cannot tell apart, and raising the wrong one is worse than raising neither.
            return matches.count == 1 ? matches[0] : nil
        }
        return byFrame ?? byName
    }

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

    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
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

    private static func frame(of window: AXUIElement) -> CGRect? {
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

    /// A single window needs this too: clicking the prompt of a captured terminal otherwise typed into whatever window was over it.
    /// The window list, not the catalogue: its answer cannot go stale when a window is dragged.
    private static func owningProcess(of source: CaptureSource) -> pid_t? {
        switch source {
        case .application(let pid):
            return pid
        case .window(let id):
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            else { return nil }
            return info.first?[kCGWindowOwnerPID as String] as? pid_t
        case .display, .mosaic:
            // Nothing to raise: a display is every application at once, and a mosaic is a
            // composition of several, each of which is drawn where it was left.
            return nil
        }
    }

    /// activate is a request the window server may refuse for a menu-bar app with no user behind it (cooperative since macOS 14).
    /// Both: activate makes it the frontmost process (menu bar, Dock, Cmd-Tab); the AX frontmost attribute brings its windows forward.
    func bringToFront(_ application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows])
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Executable paths never cross the network.
    func launchApplication(bundleIdentifier: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            record("Could not launch application: invalid or unavailable bundle identifier", level: .failure)
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.activationPolicy == .regular }) {
            bringToFront(running)
            let target = launchTargetDisplayID
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let target {
                    await self.relocateLaunchedApplication(running, toDisplay: target)
                }
                self.switchToLaunchedApplication(running)
            }
            return
        }

        let target = launchTargetDisplayID
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.record("Could not launch application: \(error.localizedDescription)", level: .failure)
                    return
                }
                guard let application else {
                    self.record("Application launched but no running process was returned", level: .failure)
                    return
                }
                self.record("Opened \(application.localizedName ?? bundleIdentifier)")
                // Asked for directly: activates = true is a request macOS stopped guaranteeing in 14, and again after the windows exist.
                self.bringToFront(application)
                self.coordinator?.refreshCatalog()
                if let target {
                    await self.relocateLaunchedApplication(application, toDisplay: target)
                }
                self.bringToFront(application)
                self.switchToLaunchedApplication(application)
            }
        }
    }

    /// The display the client is looking at, since a launch otherwise opens on the built-in screen. Falls back to a phone-requested display if one exists.
    var launchTargetDisplayID: UInt32? {
        if case .display(let id) = capturingSource { return id }
        return managedVirtualDisplays.first?.displayID
    }

    /// Spaces pair windows with displays: moving a window onto another display joins the Space it is showing, so no Space switch is needed.
    /// Polled: a launch completion can precede the app having a window.
    func relocateLaunchedApplication(_ application: NSRunningApplication, toDisplay displayID: UInt32) async {
        for attempt in 0..<20 {
            if relocateWindows(ofPID: application.processIdentifier, toDisplay: displayID) { return }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func relocateWindows(ofPID pid: pid_t, toDisplay displayID: UInt32) -> Bool {
        var ref: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return false }

        let bounds = CGDisplayBounds(displayID)
        for (index, window) in windows.enumerated() {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
                  settable.boolValue
            else { continue }

            var size = CGSize.zero
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            }

            // Cascaded so windows do not stack, and clamped so a window sized for the Mac does not spill off a small virtual display.
            let offset = CGFloat(index) * 24
            let maxX = max(bounds.minX, bounds.maxX - size.width)
            let maxY = max(bounds.minY, bounds.maxY - size.height)
            var origin = CGPoint(
                x: min(bounds.minX + 40 + offset, maxX),
                y: min(bounds.minY + 40 + offset, maxY)
            )

            guard let value = AXValueCreate(.cgPoint, &origin) else { continue }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        return true
    }

    func switchToLaunchedApplication(_ application: NSRunningApplication) {
        guard let coordinator else {
            record("Application opened; capture is not connected", level: .warning)
            return
        }
        let source = CaptureSource.application(application.processIdentifier)
        pendingCaptureSource = source

        // Polled: a launch completion can precede the first capturable window.
        Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            var lastError: Error?
            for attempt in 0..<20 {
                do {
                    try await coordinator.switchSource(source)
                    await MainActor.run { self.pendingCaptureSource = nil }
                    return
                } catch {
                    lastError = error
                    if attempt < 19 {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            if let lastError { Analytics.failed(lastError, in: .appLaunching) }
            let message: LocalizedStringResource = lastError.map(HostFailureText.resource(for:))
                ?? "The application did not expose a capturable window."
            await MainActor.run { self.record("Could not switch to application: \(message)", level: .failure) }
        }
    }
}
