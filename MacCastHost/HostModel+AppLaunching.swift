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
    func raiseApplication(for source: CaptureSource) {
        guard case .application(let pid) = source,
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        running.activate(options: [.activateAllWindows])
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
            running.activate()
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
                self.coordinator?.refreshCatalog()
                if let target {
                    await self.relocateLaunchedApplication(application, toDisplay: target)
                }
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
    /// Falls back to the virtual display whenever one exists, even while the client is looking at
    /// a single captured application: that display's Space is what the phone otherwise treats as
    /// home, and a launch has nowhere else meaningful to prefer.
    var launchTargetDisplayID: UInt32? {
        if case .display(let id) = capturingSource { return id }
        return virtualDisplay?.displayID
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
