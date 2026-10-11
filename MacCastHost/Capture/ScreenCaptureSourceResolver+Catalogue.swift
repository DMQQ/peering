import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension ScreenCaptureSourceResolver {
    func catalog() async throws -> CaptureCatalog {
        let content = try await shareableContent()
        // Sources a capture proved uncapturable are not offered. See ``uncapturable``.
        let offTheList = lock.withLock { uncapturable }
        let now = Date()
        // Asked live: the snapshot's on-screen flags describe whichever desktop was showing when it was taken.
        let candidates = content.windows.filter { $0.windowLayer == 0 }.map(\.windowID)
        let elsewhere = await MainActor.run { windowsOrderedInOnSpaces(candidates) }
        lock.withLock { openOnSomeDesktop = elsewhere }
        let descriptors = Self.descriptors(from: content, elsewhere: elsewhere).filter { descriptor in
            guard let marked = offTheList[descriptor.source] else { return true }
            return now.timeIntervalSince(marked) >= Self.uncapturableGrace
        }
        let runningBundleIDs = Set(descriptors.compactMap(\.bundleIdentifier))
        let installed = lock.withLock { installedApplicationsCache }
            ?? Self.installedApplications()
        lock.withLock { installedApplicationsCache = installed }

        // Space info must be read on the main thread (CGS connection is thread-local).
        let spaceDisplays: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        // Skipped on an empty read: it is indistinguishable from a failed read and would discard every picture.
        if !spaceDisplays.isEmpty {
            spacePreviews.keep(only: Set(spaceDisplays.flatMap(\.ids)))
        }
        let spaceInfo = spaceDisplays.isEmpty ? nil : SpaceInfo(
            displays: spaceDisplays.map { display in
                // Desktops only: a fullscreen app's Space is not somewhere the client can be sent. See ``ManagedSpace``.
                SpaceDisplay(
                    displayID: display.displayID,
                    count: display.desktopIDs.count,
                    current: display.current,
                    previews: spacePreviews.previews(ids: display.desktopIDs)
                )
            }
        )

        // Logged because `prefix` silently truncates the list, which reads as a broken picker.
        let offered = installed.filter { !runningBundleIDs.contains($0.bundleIdentifier) }
        if offered.count > CaptureCatalog.maximumInstalledApplicationCount {
            resolverLog.notice("""
                \(offered.count, privacy: .public) installed applications found, \
                \(CaptureCatalog.maximumInstalledApplicationCount, privacy: .public) sent
                """)
        }

        // A row with no picture lets the client draw its own outline. Applications carry none: their rows are icons.
        let pictured = descriptors.filter { $0.kind == .display || $0.kind == .window }
        // Pruned so a picture outlives neither an unplugged display nor a closed window.
        sourceThumbnails.keep(only: Set(pictured.map(\.id)))

        let withPictures = pictured.map {
            $0.withThumbnail(sourceThumbnails.thumbnail(for: $0.source))
        }

        return CaptureCatalog(
            displays: withPictures.filter { $0.kind == .display },
            applications: descriptors.filter { $0.kind == .application },
            windows: withPictures.filter { $0.kind == .window },
            installedApplications: offered,
            spaceInfo: spaceInfo
        )
    }

    /// Two callers racing the first enumeration both enumerate: a duplicated round trip, cheaper than holding a lock across an `await`.
    func shareableContent() async throws -> SCShareableContent {
        if let cached = lock.withLock({ isStale ? nil : snapshot }) { return cached }

        let fresh: SCShareableContent
        do {
            // Desktop windows are excluded: they make the list enormous. Which windows reach the phone is decided in ``isUserFacingWindow(_:)``.
            fresh = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            Analytics.failed(error, in: .capture)
            throw CaptureError.from(error)
        }

        let (content, note) = lock.withLock { serve(fresh) }
        if let note { resolverLog.notice("\(note, privacy: .public)") }
        return content
    }

    /// A reading with no window in it is not this Mac: every row is built from a window, and ScreenCaptureKit returns such readings for a beat around a Space change, which would empty the picker while cached.
    /// So a first such reading is not cached and the last good one is served; windowless readings ``windowlessReadGrace`` apart must agree before a Mac with nothing open is believed. Under ``lock``.
    private func serve(_ fresh: SCShareableContent) -> (SCShareableContent, String?) {
        // A display that is asleep reports no displays and no windows, which is the Mac resting rather than empty. Counting those reads toward the grace let a morning's worth of them expire it, so the first read after the display woke was believed and a connecting phone saw nothing to capture.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0, fresh.displays.isEmpty || Self.foundNoWindow(fresh) {
            firstWindowlessReadAt = nil
            isStale = true
            return (snapshot ?? fresh, nil)
        }

        guard Self.foundNoWindow(fresh) else {
            firstWindowlessReadAt = nil
            snapshot = fresh
            windowIDsAtSnapshot = Self.liveWindowIDs()
            isStale = false
            return (fresh, nil)
        }

        let first = firstWindowlessReadAt ?? Date()
        let isFirstOfEpisode = firstWindowlessReadAt == nil
        firstWindowlessReadAt = first
        let doubtedFor = Date().timeIntervalSince(first)

        guard doubtedFor < Self.windowlessReadGrace else {
            snapshot = fresh
            windowIDsAtSnapshot = Self.liveWindowIDs()
            isStale = false
            return (fresh, """
                no window on any display for \(Int(doubtedFor.rounded()))s; \
                taking the enumeration at its word
                """)
        }

        // Left stale so the next caller re-reads instead of getting this reading back.
        isStale = true
        let serving = snapshot ?? fresh
        let note = isFirstOfEpisode
            ? "the enumeration found no window on any display, so the last listing stands until the next reading agrees"
            : nil
        return (serving, note)
    }

    private static func foundNoWindow(_ content: SCShareableContent) -> Bool {
        !content.windows.contains { isUserFacingWindow($0) }
    }

    /// ``invalidate()`` without the notification: a push going out while this caller is still working would arrive behind its result.
    func markStale() {
        lock.withLock { isStale = true }
    }

    /// Reads the window server, which answers in a millisecond where a new snapshot costs seconds. A stale frame puts every tap and scroll in the wrong place.
    func invalidateIfWindowsMoved() {
        guard let content = lock.withLock({ isStale ? nil : snapshot }) else { return }
        guard let live = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return }
        var frames: [CGWindowID: CGRect] = [:]
        for info in live {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            frames[id] = rect
        }
        let moved = content.windows.contains { window in
            guard let now = frames[window.windowID] else { return false }
            let then = window.frame
            return abs(now.minX - then.minX) > 1 || abs(now.minY - then.minY) > 1
                || abs(now.width - then.width) > 1 || abs(now.height - then.height) > 1
        }
        if moved { invalidate() }
    }

    /// Nothing announces a window opening or closing. Compared against the window server's list, since ScreenCaptureKit's leaves out windows it lists.
    func invalidateIfWindowsOpenedOrClosed() {
        guard let then = lock.withLock({ isStale ? nil : windowIDsAtSnapshot }) else { return }
        guard Self.liveWindowIDs() != then else { return }
        markStale()
        onInvalidate?(false)
    }

    private static func isOnScreen(windowID: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else { return false }
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private static func liveWindowIDs() -> Set<CGWindowID> {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return Set(windows.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? CGWindowID : nil
        })
    }

    /// Polls up to ten seconds for a launched application's first window, then pushes at once.
    private func relistWhenFirstWindowOpens(processID: pid_t) async {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard Self.hasOnScreenWindow(processID: processID) else { continue }
            lock.withLock { isStale = true }
            onInvalidate?(true)
            return
        }
    }

    static func hasOnScreenWindow(processID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        return windows.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == processID
                && (info[kCGWindowLayer as String] as? Int) == 0
        }
    }

    func invalidate() {
        let changed = lock.withLock { () -> Bool in
            let wasCurrent = !isStale
            isStale = true
            // A window that would not render may render now. See ``uncapturable``.
            uncapturable = [:]
            return wasCurrent
        }
        guard changed else { return }
        resolverLog.debug("capture catalogue invalidated")
        onInvalidate?(false)
    }

    private static let uncapturableGrace: TimeInterval = 60

    func markUncapturable(_ source: CaptureSource) {
        // Many apps stop drawing windows on a desktop that is not showing; that is where it is, not what it is.
        if case .window(let id) = source,
           lock.withLock({ openOnSomeDesktop.contains(id) }),
           !Self.isOnScreen(windowID: id) {
            return
        }
        let announced = lock.withLock { () -> Bool in
            isStale = true
            let wasMarked = uncapturable[source]
                .map { Date().timeIntervalSince($0) < Self.uncapturableGrace } ?? false
            uncapturable[source] = Date()
            return !wasMarked
        }
        guard announced else { return }
        resolverLog.notice("""
            \(source.stableID, privacy: .public) produced no picture when it was asked for one; \
            it is off the list for \(Int(Self.uncapturableGrace), privacy: .public)s
            """)
        // Announced, unlike ``invalidate()``: this push takes the tile out of the phone's arrangement.
        onInvalidate?(false)
    }

    func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        // Launch and terminate, not activate: switching apps adds nothing to capture. Window opens and closes have no notification, hence ``makeFilter(for:)`` re-checks the window.
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didLaunchApplicationNotification),
            (workspace, NSWorkspace.didTerminateApplicationNotification),
            (center, NSApplication.didChangeScreenParametersNotification),
        ]

        for (source, name) in names {
            let observer = source.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            }
            observers.append(observer)
        }

        // An app has no window at launch and no notification says when its first opens, so the window server is polled.
        let launchObserver = workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            let pid = app.processIdentifier
            Task { await self?.relistWhenFirstWindowOpens(processID: pid) }
        }
        observers.append(launchObserver)

        // Not above: a Space change alters nothing capturable, so invalidating would cost a full re-enumeration per switch.
        let spaceObserver = workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.lock.withLock { self?.spaceChangeGeneration += 1 }
            Task { await self?.captureActiveSpacePreview() }
        }
        observers.append(spaceObserver)
    }
}
