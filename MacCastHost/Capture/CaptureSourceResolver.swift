import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let resolverLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A filter for a capture source and the region of it worth streaming. Only correct as a pair: the rectangle is in the filter's coordinate space, so taking one without the other crops the wrong part silently.
struct CaptureFilterPlan {
    let filter: SCContentFilter

    /// In points in the display's logical space (what `SCStreamConfiguration.sourceRect` documents). `nil` for a whole display or a `desktopIndependentWindow` filter.
    let sourceRect: CGRect?
}

protocol CaptureSourceResolver: Sendable {
    func catalog() async throws -> CaptureCatalog

    /// Requires a prior ``catalog()`` call.
    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan

    func inputTransform(for source: CaptureSource) -> InputTransform

    /// Moves to the desktop an application is on when it is not showing, since an application's capture is built from on-screen windows. A window needs no move.
    func bringOnScreen(_ source: CaptureSource) async

    /// Re-photographs the desktop showing on each display, ahead of the age check.
    func refreshSpacePreviews() async

    /// Asked for by ``RemoteCommand/refreshSourceThumbnails``. No schedule or age check: only the client knows a grid is on screen.
    func refreshSourceThumbnails() async

    /// One pass of the watch loop: pushes the catalogue only when a picture changed. Re-enumerating windows costs far more than the screenshots, so only when `reenumerate`.
    func refreshChangedSourceThumbnails(reenumerate: Bool) async

    func refreshChangedSpacePreviews() async

    /// No notification covers a window closing, so a capture noticing is the only way to find out. Also forgets uncapturable marks, since a launch, quit or screen change changes that answer. See ``markUncapturable(_:)``.
    func invalidate()

    func invalidateIfWindowsMoved()

    /// ScreenCaptureKit lists windows it will not render; only a capture that produced no frame separates them. See ``ScreenCaptureSourceResolver/uncapturable``.
    func markUncapturable(_ source: CaptureSource)

    /// A screenshot, not a stream frame: reaching into the capture queue for a thumbnail would put this window's refresh in front of the phone's.
    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage?
}

/// A lock-guarded class rather than an actor: the ScreenCaptureKit types carry no `Sendable` annotations, so an actor boundary buys no checked safety and forces `await` everywhere.
/// Listens for the notifications that change the catalogue and marks the snapshot stale, rather than polling.
final class ScreenCaptureSourceResolver: CaptureSourceResolver, @unchecked Sendable {
    private let lock = NSLock()

    /// Kept because ``makeFilter(for:)`` is synchronous and needs the same `SCWindow`/`SCDisplay` instances the catalogue used.
    private var snapshot: SCShareableContent?
    private var installedApplicationsCache: [InstalledApplicationDescriptor]?
    private var isStale = true

    /// Window numbers when ``snapshot`` was taken. Under ``lock``.
    private var windowIDsAtSnapshot: Set<CGWindowID>?

    private var openOnSomeDesktop: Set<CGWindowID> = []

    /// When an enumeration with no window in it was first seen. See ``serve(_:)``. Under ``lock``.
    private var firstWindowlessReadAt: Date?

    /// Several times the length of the Space change that produces windowless readings.
    private static let windowlessReadGrace: TimeInterval = 6
    private var observers: [NSObjectProtocol] = []

    private let spacePreviews = SpacePreviewCache()

    /// Keyed by ``CaptureSource/stableID`` so an application keeps its picture across catalogue rebuilds.
    private let sourceThumbnails = SourceThumbnailCache()

    /// `activeSpaceDidChangeNotification` does not say which display changed; without this every display would be photographed on every switch. Under ``lock``.
    private var lastActiveSpace: [UInt32: Int32] = [:]

    /// Window changes on a showing desktop announce nothing, so this lets ``captureActiveSpacePreview()`` re-shoot a desktop nobody has left. Under ``lock``.
    private var lastPreviewAt: [UInt32: DispatchTime] = [:]

    /// The window server reports the new Space ID as soon as a switch starts, so only time since arrival tells a finished desktop from one still sliding in. Under ``lock``.
    private var spaceArrivedAt: [UInt32: DispatchTime] = [:]

    /// Bumped when a Space switch starts. The Space ID moves late, so a shot taken as a switch begins shows the desktop being left; it is filed only if this has not moved ``postShutterHold`` later. Under ``lock``.
    private var spaceChangeGeneration = 0

    private var spacePoll: Task<Void, Never>?

    /// A switch on a second display can pass with no notification, so the notification is only the fast path and this poll is the one that is always right.
    private static let spacePollInterval: Duration = .seconds(2)

    /// Long enough that a desktop being worked on is not photographed every couple of seconds, short enough to look current.
    private static let spacePreviewMaxAgeNanoseconds: UInt64 = 12 * 1_000_000_000

    /// Fired when the catalogue is out of date; the host re-reads ``catalog()`` and pushes, since pushing from inside the notification would be an unrelated thread.
    /// The flag is whether the push must go out now: pushes coalesce to three seconds, which would leave a waiting preview as a grey outline. See ``previewLanded()``.
    private let onInvalidate: (@Sendable (Bool) -> Void)?

    init(onInvalidate: (@Sendable (Bool) -> Void)? = nil) {
        self.onInvalidate = onInvalidate
        registerObservers()

        // A desktop can only be photographed while it is on the display, so one visited before the client connected would otherwise have no picture.
        Task { [weak self] in await self?.captureActiveSpacePreview() }

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.spacePollInterval)
                guard !Task.isCancelled, let self else { return }
                self.invalidateIfWindowsOpenedOrClosed()
                await self.captureActiveSpacePreview()
            }
        }
        spacePoll = poll
    }

    deinit {
        spacePoll?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Catalogue

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
    private func shareableContent() async throws -> SCShareableContent {
        if let cached = lock.withLock({ isStale ? nil : snapshot }) { return cached }

        let fresh: SCShareableContent
        do {
            // Desktop windows are excluded: they make the list enormous. Which windows reach the phone is decided in ``isUserFacingWindow(_:)``.
            fresh = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.from(error)
        }

        let (content, note) = lock.withLock { serve(fresh) }
        if let note { resolverLog.notice("\(note, privacy: .public)") }
        return content
    }

    /// A reading with no window in it is not this Mac: every row is built from a window, and ScreenCaptureKit returns such readings for a beat around a Space change, which would empty the picker while cached.
    /// So a first such reading is not cached and the last good one is served; windowless readings ``windowlessReadGrace`` apart must agree before a Mac with nothing open is believed. Under ``lock``.
    private func serve(_ fresh: SCShareableContent) -> (SCShareableContent, String?) {
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
    private func markStale() {
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
    private func invalidateIfWindowsOpenedOrClosed() {
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

    private static func hasOnScreenWindow(processID: pid_t) -> Bool {
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

    /// Sources a capture proved this Mac cannot capture, and when. Only a capture that produced no frame at all is evidence.
    /// Dated so a mark expires after ``uncapturableGrace``: marks used to stand until invalidation, so a window that failed once mid-Space switch (Terminal, Zed) vanished from the phone for the session. Emptied by ``invalidate()``. Under ``lock``.
    private var uncapturable: [CaptureSource: Date] = [:]

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

    private func registerObservers() {
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

    // MARK: - Space previews

    /// The notification arrives as the switch begins; a shot taken mid-slide is half of each desktop.
    private static let spaceSwitchSettle: Duration = .milliseconds(900)

    private static let postShutterHold: Duration = .milliseconds(700)

    private static let watchedPreviewMaxAgeNanoseconds: UInt64 = 3 * 1_000_000_000

    /// Photographs desktops that just came to the front, the only ones ScreenCaptureKit can photograph. Compares against the Space each display was last seen showing, so a switch costs one screenshot.
    /// Not called from ``catalog()``: a screenshot is a window-server round trip and the catalogue is on the connect path. Best-effort; a failure only costs a tile.
    func refreshSpacePreviews() async {
        await captureActiveSpacePreview(force: true)
    }

    func refreshChangedSpacePreviews() async {
        await captureActiveSpacePreview(maxAge: Self.watchedPreviewMaxAgeNanoseconds, settle: false)
    }

    func refreshSourceThumbnails() async {
        await photographSources(reenumerate: true, pushOnlyOnChange: false)
    }

    func refreshChangedSourceThumbnails(reenumerate: Bool) async {
        await photographSources(reenumerate: reenumerate, pushOnlyOnChange: true)
    }

    private func photographSources(reenumerate: Bool, pushOnlyOnChange: Bool) async {
        // Fresh enumeration first: window opens and closes post no notification, and this runs when the user opens the picker, where a stale list shows as a fault.
        if reenumerate { markStale() }
        guard let content = try? await shareableContent() else {
            resolverLog.notice("could not re-read the capture catalogue, so the picker is showing the last one")
            return
        }
        let candidates = content.windows.filter { $0.windowLayer == 0 }.map(\.windowID)
        let elsewhere = await MainActor.run { windowsOrderedInOnSpaces(candidates) }
        let sources = Self.descriptors(from: content, elsewhere: elsewhere)
            .filter { $0.kind == .display || $0.kind == .window }
            .map(\.source)
        guard !sources.isEmpty else { return }

        let landed = await withTaskGroup(
            of: (source: CaptureSource, thumbnail: SourceThumbnail?).self
        ) { group in
            var next = 0
            var stored = 0

            // Called once per slot and once per completion, keeping the number in flight at the limit without a semaphore.
            func addNext() {
                guard next < sources.count else { return }
                let source = sources[next]
                next += 1
                group.addTask {
                    guard let image = await self.snapshot(
                        of: source, maxWidth: SourceThumbnailCache.pixelWidth
                    ) else { return (source, nil) }
                    return (source, SourceThumbnailCache.thumbnail(from: image))
                }
            }

            for _ in 0..<min(Self.thumbnailConcurrency, sources.count) { addNext() }
            while let result = await group.next() {
                if let thumbnail = result.thumbnail,
                   self.sourceThumbnails.store(thumbnail, for: result.source) {
                    stored += 1
                }
                addNext()
            }
            return stored
        }

        if pushOnlyOnChange, landed == 0 { return }
        resolverLog.debug("""
            source thumbnails: \(landed, privacy: .public) of \
            \(sources.count, privacy: .public) changed
            """)
        // Same signal as a Space preview. See ``previewLanded()``.
        previewLanded()
    }

    private static let thumbnailConcurrency = 4

    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage? {
        let pixels = inputTransform(for: source).pixelSize
        guard pixels.width > 0, pixels.height > 0, maxWidth > 0 else { return nil }

        let scale = min(1, CGFloat(maxWidth) / pixels.width)
        let plan: CaptureFilterPlan
        do {
            plan = try makeFilter(for: source)
        } catch {
            // Logged: a missing still is otherwise indistinguishable from one never asked for.
            resolverLog.notice("""
                snapshot of \(source.stableID, privacy: .public) has no filter: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int((pixels.width * scale).rounded())
        configuration.height = Int((pixels.height * scale).rounded())
        configuration.backgroundColor = CGColor.black
        configuration.showsCursor = true
        // Same crop as the stream, or a multi-window app sits in the middle of a black frame.
        if let sourceRect = plan.sourceRect {
            configuration.sourceRect = sourceRect
        }

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: plan.filter,
                configuration: configuration
            )
        } catch {
            // A screenshot of a window on a desktop that is not showing is refused, while a
            // stream of the same window delivers it. So one frame is taken from a stream instead.
            if case .window = source,
               let still = await FirstFrameGrabber.still(filter: plan.filter, configuration: configuration) {
                return still
            }
            resolverLog.notice("""
                snapshot of \(source.stableID, privacy: .public) was refused: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    /// - Parameter force: ignore the age check; for a client about to show the pictures.
    /// - Parameter settle: wait out a Space switch animation. Only a caller that knows none is under way may skip it.
    func captureActiveSpacePreview(
        force: Bool = false, maxAge: UInt64 = spacePreviewMaxAgeNanoseconds, settle: Bool = true
    ) async {
        // Decided before the settle so a notification during it does not make this call act on a display it was never about; recorded here so one arriving mid-flight does not queue a display twice.
        let before: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        let (changed, settledAt) = lock.withLock { () -> ([UInt32], DispatchTime) in
            let now = DispatchTime.now()
            var due: [UInt32] = []
            var latestArrival = DispatchTime(uptimeNanoseconds: 0)
            for display in before {
                let arrived = lastActiveSpace[display.displayID] != display.activeID
                lastActiveSpace[display.displayID] = display.activeID
                if arrived {
                    spaceArrivedAt[display.displayID] = now
                    spaceChangeGeneration += 1
                }

                // Aged out too: the desktop the user sits on goes most stale, since nothing announces a window opening on it.
                let age = lastPreviewAt[display.displayID].map {
                    now.uptimeNanoseconds - $0.uptimeNanoseconds
                } ?? .max

                if force || arrived || age >= maxAge {
                    // Recorded at the decision, so a failed capture does not re-arm this on the next tick.
                    lastPreviewAt[display.displayID] = now
                    due.append(display.displayID)
                    if let at = spaceArrivedAt[display.displayID], at > latestArrival {
                        latestArrival = at
                    }
                }
            }
            return (due, latestArrival)
        }
        guard !changed.isEmpty else { return }

        // Waited out from the arrival, whatever `settle` says: the picker watch sees switches often enough that skipping the wait photographed desktops mid-slide.
        let settleNanoseconds = UInt64(Self.spaceSwitchSettle.components.seconds) * 1_000_000_000
            + UInt64(Self.spaceSwitchSettle.components.attoseconds / 1_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - settledAt.uptimeNanoseconds
        if settle || elapsed < settleNanoseconds {
            let remaining = settleNanoseconds - min(elapsed, settleNanoseconds)
            try? await Task.sleep(for: settle ? Self.spaceSwitchSettle : .nanoseconds(remaining))
        }

        // Read again after the settle: the earlier read can name a desktop the user has left, and filing under it would put one desktop's picture under another's name.
        let settled: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        // A display that moved on during the wait is left to the call that saw it arrive; shooting it here caught it mid-slide.
        let targets = settled.filter { display in
            changed.contains(display.displayID)
                && before.first { $0.displayID == display.displayID }?.activeID == display.activeID
        }
        guard !targets.isEmpty else { return }

        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            // Reported as itself: this is where a host without Screen Recording fails, and blaming the hardware would mislead.
            resolverLog.notice("""
                space previews not captured: \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        var landed = false
        for display in targets {
            let generation = lock.withLock { spaceChangeGeneration }
            guard let screen = content.displays.first(where: { $0.displayID == display.displayID }) else {
                resolverLog.notice("""
                    display \(display.displayID, privacy: .public) is not shareable, \
                    so no preview of space \(display.activeID, privacy: .public)
                    """)
                continue
            }
            guard let shot = await spacePreviews.capture(
                spaceID: display.activeID,
                filter: SCContentFilter(display: screen, excludingWindows: []),
                configuration: Self.previewConfiguration(for: screen)
            ) else { continue }
            try? await Task.sleep(for: Self.postShutterHold)

            // Read after the shutter: the person can switch again during the enumeration and capture. Discarded rather than re-filed on disagreement, since a tile keeping an older picture is a smaller wrong than one showing the wrong desktop.
            let afterShutter: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
            guard afterShutter.first(where: { $0.displayID == display.displayID })?.activeID
                    == display.activeID,
                  lock.withLock({ spaceChangeGeneration }) == generation
            else {
                resolverLog.notice("""
                    space \(display.activeID, privacy: .public) moved under the shutter; \
                    the preview is discarded rather than filed under the wrong desktop
                    """)
                continue
            }

            if spacePreviews.store(shot, for: display.activeID) { landed = true }
        }
        guard landed else { return }

        previewLanded()
    }

    /// A change to the catalogue that no source-list notification covers. Goes through `onInvalidate` but not ``invalidate()``, which suppresses the call when already stale and would drop a preview landing behind a launch.
    /// At once, not on the interval: the phone is drawing outlines until these arrive.
    private func previewLanded() {
        onInvalidate?(true)
    }

    /// Height follows the display's ratio: `SCStreamConfiguration` preserves aspect ratio, so a mismatched height letterboxes the desktop.
    private static func previewConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let width = SpacePreviewCache.pixelWidth
        // A zero height is rejected by ScreenCaptureKit, so a display reporting nothing gets a plausible shape.
        let ratio = display.width > 0 && display.height > 0
            ? Double(display.height) / Double(display.width)
            : 10.0 / 16.0

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int((Double(width) * ratio).rounded()))
        // Nominal: at .best a full 6K surface per desktop would be composited and nearly all discarded in the downscale.
        configuration.captureResolution = .nominal
        // A desktop thumbnail with a pointer would show it frozen for as long as the user stays on that Space.
        configuration.showsCursor = false
        return configuration
    }


    // MARK: - Descriptors

    private static func descriptors(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID> = []
    ) -> [CaptureSourceDescriptor] {
        // One icon encode per process, shared between an application's row and its windows' rows; the catalogue is rebuilt on every launch and quit.
        var icons = ApplicationIcons()
        let displayRows = displays(from: content)
        let applicationRows = applications(from: content, elsewhere: elsewhere, icons: &icons)
        let windowRows = windows(from: content, elsewhere: elsewhere, icons: &icons)
        return displayRows + applicationRows + windowRows
    }

    /// Keyed by process, the identity `SCRunningApplication` and `SCWindow.owningApplication` hand out.
    private struct ApplicationIcons {
        private var byProcess: [pid_t: Data?] = [:]

        /// `nil` is remembered as an answer: a process may have no icon.
        mutating func icon(for processID: pid_t) -> Data? {
            if let cached = byProcess.index(forKey: processID) {
                return byProcess[cached].value
            }
            let data = ScreenCaptureSourceResolver.applicationIcon(for: processID)
            byProcess[processID] = data
            return data
        }
    }

    /// `NSRunningApplication.icon` can briefly be nil while an app launches; the bundle icon is available earlier.
    private static func applicationIcon(for processID: pid_t) -> Data? {
        guard let running = NSRunningApplication(processIdentifier: processID) else { return nil }
        if let data = iconPNGData(for: running) { return data }
        guard let bundleURL = running.bundleURL else { return nil }
        return iconPNGData(for: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    private static func displays(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.displays.compactMap { display in
            // `SCDisplay.width`/`height` are points; the pixel mapping needs pixels, or the remote cursor drifts the further it is dragged.
            let pixelWidth = CGDisplayPixelsWide(display.displayID)
            let pixelHeight = CGDisplayPixelsHigh(display.displayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            return CaptureSourceDescriptor(
                kind: .display,
                title: screenName(for: display.displayID) ?? "Display \(display.displayID)",
                subtitle: "\(pixelWidth)×\(pixelHeight)",
                source: .display(display.displayID),
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                // Only a display the phone asked for; tells the client which rows it may rename and remove.
                isManagedVirtualDisplay: VirtualDisplay.isPhoneManaged(display.displayID),
                // Exists only in software at all; `VirtualDisplay.name(for:)` is non-nil for exactly those.
                isVirtualDisplay: VirtualDisplay.name(for: display.displayID) != nil
            )
        }
    }

    private static func applications(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID>,
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var seenBundleIDs = Set<String>()
        var seenNames = Set<String>()
        var result: [CaptureSourceDescriptor] = []

        for application in content.applications {
            let running = NSRunningApplication(processIdentifier: application.processID)
            // ScreenCaptureKit includes agents, menu extras and system surfaces.
            guard running?.activationPolicy == .regular else { continue }
            // A list of identifiers, not a check on bundle location: that would exclude Terminal (`/System/Applications`) and Safari (App cryptex), and these three report a regular activation policy on some macOS versions.
            if let bundleIdentifier = running?.bundleIdentifier,
               Self.isSystemSurface(bundleIdentifier) {
                continue
            }

            let owned = content.windows.filter {
                $0.owningApplication?.processID == application.processID
                    && isUserFacingWindow($0, elsewhere: elsewhere)
            }
            guard let bounds = unionFrame(of: owned) else { continue }

            let title = name(for: application, processID: application.processID)
            let bundleIdentifier = running?.bundleIdentifier
            if let bundleIdentifier {
                guard seenBundleIDs.insert(bundleIdentifier).inserted else { continue }
            } else {
                guard seenNames.insert(title.localizedLowercase).inserted else { continue }
            }

            let scale = backingScale(for: bounds)
            let iconData = icons.icon(for: application.processID)

            result.append(CaptureSourceDescriptor(
                kind: .application,
                // Not `application.applicationName` directly: it is empty for some processes, leaving an unidentifiable blank cell.
                title: title,
                subtitle: owned.count == 1 ? "1 window" : "\(owned.count) windows",
                bundleIdentifier: bundleIdentifier,
                iconPNGData: iconData,
                source: .application(application.processID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            ))
        }

        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A name for an application that is never empty.
    ///
    /// ScreenCaptureKit's own name is preferred, since it is what the application calls itself.
    /// The fallbacks go through `NSRunningApplication` and only then name it by pid, which is the
    /// identity the client sends back: never wrong, just less readable. An empty string is
    /// unusable.
    private static func name(for application: SCRunningApplication, processID: pid_t) -> String {
        let candidates = [
            application.applicationName,
            NSRunningApplication(processIdentifier: processID)?.localizedName,
            NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
        ]
        for candidate in candidates {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "Application \(processID)"
    }

    private static func windows(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID>,
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var result: [CaptureSourceDescriptor] = []

        for window in content.windows {
            guard isUserFacingWindow(window, elsewhere: elsewhere) else { continue }
            guard let application = window.owningApplication, let bounds = unionFrame(of: [window]) else {
                continue
            }
            let running = NSRunningApplication(processIdentifier: application.processID)
            guard running?.activationPolicy == .regular else { continue }

            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? application.applicationName
            let scale = backingScale(for: bounds)

            result.append(CaptureSourceDescriptor(
                kind: .window,
                title: title,
                subtitle: application.applicationName,
                bundleIdentifier: running?.bundleIdentifier,
                iconPNGData: icons.icon(for: application.processID),
                source: .window(window.windowID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            ))
        }

        return result.sorted { lhs, rhs in
            let applicationOrder = (lhs.subtitle ?? "").localizedStandardCompare(rhs.subtitle ?? "")
            if applicationOrder != .orderedSame { return applicationOrder == .orderedAscending }

            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// On screen, or in `elsewhere` (open on a desktop that is not showing, which still streams). A closed-but-unreleased or minimised window is neither; ScreenCaptureKit lists both and renders neither.
    private static func isUserFacingWindow(_ window: SCWindow, elsewhere: Set<CGWindowID> = []) -> Bool {
        guard window.windowLayer == 0,
              window.isOnScreen || elsewhere.contains(window.windowID),
              window.frame.width >= 1,
              window.frame.height >= 1
        else { return false }
        // By owner too: system surfaces report a regular activation policy and own windows that look ordinary, so the application rows' rule applies here as well.
        if let bundleIdentifier = NSRunningApplication(
            processIdentifier: window.owningApplication?.processID ?? 0
        )?.bundleIdentifier, isSystemSurface(bundleIdentifier) {
            return false
        }
        return !isNamelessSurface(window)
    }

    /// A net under ``isSystemSurface(_:)``: a regular application's untitled surface. Such a surface lists and photographs black and a stream for it says nothing, leaving an unpressable picker row (a Dictionary window titled "Window").
    /// Matched as a set of localised words ("Fenêtre" on a French Mac); only the standalone word counts, so "Window Manager" is left alone.
    private static func isNamelessSurface(_ window: SCWindow) -> Bool {
        guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return systemWindowTitles.contains(title.lowercased())
    }

    private static let systemWindowTitles: Set<String> = [
        "window", "fenêtre", "fenster", "ventana", "finestra", "venster", "okno", "ikkuna",
    ]

    /// A short identifier list plus a name pattern: `<Name>UIService` processes (lookup popovers, share sheets) own untitled windows and cannot be enumerated. Traced with ``Tools/CaptureProbe`` from `LinkedNotesUIService`, a 254x254 "Window" on layer 25. See ``isNamelessSurface(_:)``.
    private static func isSystemSurface(_ bundleIdentifier: String) -> Bool {
        systemSurfaces.contains(bundleIdentifier) || bundleIdentifier.hasSuffix("UIService")
    }

    /// Regular by activation policy, and not applications.
    private static let systemSurfaces: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.wallpaper.agent",
        "com.apple.WindowManager",
    ]

    private static func installedApplications() -> [InstalledApplicationDescriptor] {
        // The system domain is where Terminal (`/System/Applications`) and Safari (App cryptex) live; a symlink in `/Applications` does not lead an enumerator there.
        let roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask, .systemDomainMask]
        )
        var byBundleIdentifier: [String: InstalledApplicationDescriptor] = [:]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      !bundleIdentifier.isEmpty,
                      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true
                else { continue }

                let title = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                guard !title.isEmpty else { continue }

                let icon = NSWorkspace.shared.icon(forFile: url.path)
                byBundleIdentifier[bundleIdentifier] = InstalledApplicationDescriptor(
                    bundleIdentifier: bundleIdentifier,
                    title: title,
                    iconPNGData: iconPNGData(for: icon)
                )
            }
        }

        return byBundleIdentifier.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func iconPNGData(for application: NSRunningApplication) -> Data? {
        guard let icon = application.icon else { return nil }
        return iconPNGData(for: icon)
    }

    /// Downsamples before PNG encoding: a 1024-point icon would cost megabytes of control-channel data. 128 pixels, since the grid draws 74 points at three times the pixels and 48 read as a blurred square.
    private static func iconPNGData(for icon: NSImage) -> Data? {
        let dimension = 128
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        var proposedRect = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        guard let source = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: proposedRect)
        guard let scaled = context.makeImage() else { return nil }
        let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        guard let data, data.count <= CaptureSourceDescriptor.maximumIconByteCount else { return nil }
        return data
    }

    /// A degenerate frame means minimised or off-screen; its zero size would divide by zero in the coordinate mapping.
    private static func unionFrame(of windows: [SCWindow]) -> CGRect? {
        let frames = windows.map(\.frame).filter { $0.width >= 1 && $0.height >= 1 }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Windows on other desktops

    func bringOnScreen(_ source: CaptureSource) async {
        let windowID: CGWindowID
        switch source {
        case .window:
            // Streamed from wherever it is; the Mac goes there on the first touch. See ``OffDesktopInputGate``.
            return
        case .application(let pid):
            // An application's filter is built from its on-screen windows, and the snapshot's answer is from whichever desktop was showing when it was taken.
            guard !Self.hasOnScreenWindow(processID: pid),
                  let content = lock.withLock({ snapshot })
            else { markStale(); return }
            let owned = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            let ownedIDs = owned.map(\.windowID)
            let elsewhere = await MainActor.run { windowsOrderedInOnSpaces(ownedIDs) }
            guard let first = ownedIDs.first(where: elsewhere.contains) else {
                markStale()
                return
            }
            windowID = first
        default:
            return
        }
        guard await MainActor.run(body: { switchToSpace(holding: windowID) }) else {
            markStale()
            return
        }
        try? await Task.sleep(for: Self.spaceSwitchSettle)
        markStale()
    }

    // MARK: - Filters

    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan {
        guard let content = lock.withLock({ isStale ? nil : snapshot }) else {
            throw CaptureError.catalogUnavailable
        }

        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.sourceUnavailable("That display is no longer attached.")
            }
            // Excluding rather than including: the empty exclusion list captures the whole display with desktop and menu bar.
            return CaptureFilterPlan(
                filter: SCContentFilter(display: display, excludingWindows: []),
                sourceRect: nil
            )

        case .application(let pid):
            guard let application = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.sourceUnavailable("That application is no longer running.")
            }
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid && Self.isUserFacingWindow($0)
            }
            guard !owned.isEmpty else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }

            // A single window is captured independently of its display, giving exactly the window size. With several, a display filter is the only option and `sourceRect` crops to their bounding box; otherwise the iPhone gets a large black canvas.
            if owned.count == 1 {
                return CaptureFilterPlan(
                    filter: SCContentFilter(desktopIndependentWindow: owned[0]),
                    sourceRect: nil
                )
            }

            guard let union = Self.unionFrame(of: owned),
                  let display = Self.hostingDisplay(for: union, in: content)
            else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }
            return CaptureFilterPlan(
                filter: SCContentFilter(
                    display: display,
                    including: [application],
                    exceptingWindows: []
                ),
                sourceRect: Self.sourceRect(for: union, on: display)
            )

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.sourceUnavailable("That window has been closed.")
            }
            // Desktop-independent so it keeps capturing when covered or dragged to another display; a display filter would capture whatever is drawn on top.
            return CaptureFilterPlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil
            )

        case .mosaic:
            // Reachable only by mistake: a mosaic is captured as one filter per tile, and nothing on the Mac shows the canvas.
            throw CaptureError.sourceUnavailable(
                "A mosaic is composited from its tiles rather than captured in one piece."
            )
        }
    }

    /// `SCWindow.frame` is in global points (negative origin left of the primary) while `sourceRect` is in the display's own space; passing one for the other crops the wrong part.
    /// Clamped to the display: a crop partly outside it fails rather than being trimmed.
    private static func sourceRect(for union: CGRect, on display: SCDisplay) -> CGRect? {
        // Both sides are points (`display.frame`), or a Retina display halves the crop.
        let local = union.offsetBy(
            dx: -display.frame.origin.x,
            dy: -display.frame.origin.y
        )
        let within = local.intersection(CGRect(origin: .zero, size: display.frame.size))
        return within.isNull || within.isEmpty ? nil : within
    }

    private static func hostingDisplay(for rect: CGRect?, in content: SCShareableContent) -> SCDisplay? {
        guard let rect else { return content.displays.first }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetDisplaysWithRect(rect, 16, &ids, &count) == .success, count > 0,
           let match = content.displays.first(where: { $0.displayID == ids[0] }) {
            return match
        }
        return content.displays.first
    }

    // MARK: - Input mapping

    /// Built from catalogue-time geometry, which goes stale when a window moves; the input layer should prefer the per-frame content rect from `CaptureEngine`.
    func inputTransform(for source: CaptureSource) -> InputTransform {
        guard let content = lock.withLock({ isStale ? nil : snapshot }) else { return .degenerate }

        switch source {
        case .display(let id):
            guard content.displays.contains(where: { $0.displayID == id }) else { return .degenerate }
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayPixelsWide(id)
            let pixelHeight = CGDisplayPixelsHigh(id)
            guard bounds.width > 0, pixelWidth > 0 else { return .degenerate }

            return InputTransform(
                origin: bounds.origin,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                pointPixelScale: CGFloat(pixelWidth) / bounds.width
            )

        case .application(let pid):
            let owned = content.windows.filter { $0.owningApplication?.processID == pid }
            return transform(for: Self.unionFrame(of: owned))

        case .window(let id):
            let window = content.windows.first { $0.windowID == id }
            return transform(for: window?.frame)

        case .mosaic:
            // A tap's tile decides the machine coordinate, and the host refuses input while a mosaic is the source. See ``VideoCoordinator``'s input guard.
            return .degenerate
        }
    }

    private func transform(for rect: CGRect?) -> InputTransform {
        guard let rect, rect.width > 0, rect.height > 0 else { return .degenerate }
        let scale = Self.backingScale(for: rect)
        return InputTransform(
            origin: rect.origin,
            pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
            pointPixelScale: scale
        )
    }

    // MARK: - Screen geometry

    /// 2.0 on Retina, but also the odd ratios a scaled 4K display produces.
    private static func backingScale(for rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 16, &ids, &count) == .success, count > 0 else { return 1 }

        let bounds = CGDisplayBounds(ids[0])
        guard bounds.width > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(ids[0])) / bounds.width
    }

    /// `NSScreen` is the only source of names (CoreGraphics gives a model number). The host's own virtual display has no `NSScreen`, so it falls back to ``VirtualDisplay/name(for:)``.
    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
        return screen?.localizedName ?? VirtualDisplay.name(for: displayID)
    }
}

extension InputTransform {
    /// Zero-sized rather than `nil`: capture never starts for a source not in the catalogue, so a throwing accessor would force callers to handle an impossible case.
    static let degenerate = InputTransform(origin: .zero, pixelSize: .zero, pointPixelScale: 1)
}
