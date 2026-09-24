import AppKit
import ApplicationServices
import RemoteCore

// MARK: - Launching and raising applications

extension HostModel {
    /// Brings a captured application to the front, so what the client sees and where its clicks
    /// land are the same thing.
    ///
    /// Capturing an application is not controlling it, and the gap is invisible from the client.
    /// ScreenCaptureKit composites the app's *windows*, so the client sees the app whether it is
    /// occluded, minimised or on another Space. Input goes to the HID tap, where the window server
    /// hit-tests the real screen and hands the click to whatever is genuinely at those coordinates.
    /// The user sees the app, clicks where it appears to be, and hits whatever is on top of it.
    ///
    /// `.activateAllWindows` rather than a plain activation, because ``InputTransform`` for an
    /// application is the union of every window it owns.
    ///
    /// The cost: this moves the app in front of whatever the Mac's own user was doing, and switches
    /// Spaces if its windows are elsewhere.
    func raiseSource(for source: CaptureSource) {
        guard let pid = Self.owningProcess(of: source),
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        bringToFront(running)

        // **And then that window in particular.** Bringing an application to the front does not
        // choose between its windows, and for the application that is already in front it does
        // nothing at all — which is the case a phone moving from one window of an application to
        // another one is always in. It was left looking at the window it had just left, drawn on
        // top of the one it had asked for, and the click it aimed at the new window landed in the
        // old one.
        if case .window(let id) = source {
            // **And again over the next second, because a window that has just appeared is not where
            // it will be.** The first attempt is the one that matters when the source is already on
            // screen; the rest are for the window an application made a moment ago, which has a frame
            // only once the Mac has finished placing it, and for the first window of a launch, which
            // does not exist yet when the switch returns.
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

    /// Makes one window of a process the one the Mac is looking at, and the one an injected click
    /// at its coordinates lands in.
    ///
    /// Found by its frame, because that is the only public way to say which window on the Mac a
    /// `CGWindowID` means: the accessibility API hands out its own elements, and the identifier it
    /// has for a window is not the window server's. The two agree on where a window is, both in
    /// points and in the same top-left space, so the frame is an identity here rather than a guess.
    @discardableResult
    private func focusWindow(_ windowID: CGWindowID, ofProcess pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard let target = Self.windowFrame(windowID),
              AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement]
        else { return false }

        // By its frame where a frame matches, and by its name where none does: a window the Mac has
        // not finished placing yet is at the frame it was created with, and the one thing that has
        // already settled at that moment is what it is called.
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
        guard let window = byFrame ?? byName else { return false }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        return true
    }

    /// Where the window server says a window is.
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

    /// Where accessibility says a window it handed out is.
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

    /// Which process's window this is, for the two kinds of source that have one.
    ///
    /// **A single window needs this for the same reason a whole application does**, and it went
    /// without: ScreenCaptureKit composites a window whether it is in front, behind, or on another
    /// Space, so the client is shown a window while the Mac has something else at those
    /// coordinates, and the injected click is hit-tested against the real screen. Clicking the
    /// prompt of a captured terminal therefore typed into whatever window happened to be over it.
    ///
    /// The window list rather than the resolver's catalogue: the same window server draws and
    /// hit-tests the window, so its own answer cannot be stale, and a dragged window makes a
    /// catalogue snapshot wrong within a second.
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

    /// Brings an application to the front of the Mac's own screen.
    ///
    /// **`activate` is a request the window server is free to refuse, and this host is the case it
    /// refuses.** It is a menu-bar app nobody is touching: the click that asked for this arrived over
    /// the network, so no user is behind it as far as macOS is concerned, and AppKit says in as many
    /// words that activation is not guaranteed and since macOS 14 is cooperative. The accessibility
    /// API is not gated that way, the host already holds it for moving windows, and setting the
    /// frontmost attribute is the same act as clicking the application's Dock icon.
    ///
    /// Both, because they answer different questions. `activate` asks for the app to be the frontmost
    /// *process*, which is what the menu bar, the Dock and ⌘-Tab follow; the attribute is what brings
    /// its windows forward, which is what the Mac's own user sees. Neither reports anything useful:
    /// the activation returns a Bool nobody can act on, and the AX call nothing at all.
    func bringToFront(_ application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows])
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Opens a GUI application by the bundle identifier offered in the catalogue, then follows it
    /// into application capture. Executable paths never cross the network.
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
                // **Asked for directly rather than left to the launch.** `activates = true` on the
                // configuration is a request from a process with no user behind it, which is the
                // request macOS stopped guaranteeing in 14. And once again after the windows exist:
                // an application brought forward before it has one is an application the Mac's own
                // user sees nothing of.
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

    /// The display a freshly launched app's windows should land on: the one the client is
    /// currently looking at, so the app picker never hands back a window on a desktop the phone
    /// cannot see. `NSWorkspace` has no notion of "the client's display" — left alone, a launch
    /// opens onto whatever the Mac's own window server considers current, which on a Mac driving
    /// a virtual display is the built-in screen's desktop, not the virtual one.
    ///
    /// Falls back to a phone-requested display whenever one exists, even while the client is looking
    /// at a single captured application: that display's Space is what the phone otherwise treats as
    /// home, and a launch has nowhere else meaningful to prefer.
    var launchTargetDisplayID: UInt32? {
        if case .display(let id) = capturingSource { return id }
        return managedVirtualDisplays.first?.displayID
    }

    /// Moves every window `application` currently owns onto `displayID`'s bounds.
    ///
    /// Spaces are a window/display pairing kept by the window server, not a property of the
    /// window itself: a window whose position crosses onto another display joins whatever Space
    /// that display is currently showing. So repositioning is all this needs — no Space switch,
    /// and nothing about `SpaceReader`'s chord dance applies here.
    ///
    /// Polled rather than tried once: a launch completion can precede the app actually having a
    /// window, the same race ``switchToLaunchedApplication(_:)`` already accounts for.
    func relocateLaunchedApplication(_ application: NSRunningApplication, toDisplay displayID: UInt32) async {
        for attempt in 0..<20 {
            if relocateWindows(ofPID: application.processIdentifier, toDisplay: displayID) { return }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Repositions every movable window of `pid` into `displayID`'s bounds. Returns whether it
    /// found any windows at all, which is what the poll above is waiting on.
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

            // Cascaded so a second window launched moments later is not stacked exactly on the
            // first, and clamped so a window sized for the Mac's own screen does not spill off a
            // much smaller virtual display.
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

        // A launch completion can precede creation of the first capturable window, so poll the
        // observable result rather than assuming a live process means SCK has something to capture.
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
            let message = (lastError as? LocalizedError)?.errorDescription
                ?? lastError.map(String.init(describing:))
                ?? "The application did not expose a capturable window."
            await MainActor.run { self.record("Could not switch to application: \(message)", level: .failure) }
        }
    }
}
