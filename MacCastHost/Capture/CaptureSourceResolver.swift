import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let resolverLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Answers the three questions the rest of the pipeline has about capture sources: what can
/// be captured, how to configure a stream for one of them, and where that content sits on
/// screen so client coordinates can be mapped into it.
///
/// The seam exists because nothing in the host can be tested on a machine without Screen
/// Recording permission, so the pipeline can be driven by a fake catalogue in tests.
/// A filter for a capture source, and the region of it worth streaming.
///
/// They are only correct as a pair: the rectangle is in the filter's coordinate space, so
/// taking one without the other crops the wrong part of the wrong thing, and does it silently.
struct CaptureFilterPlan {
    let filter: SCContentFilter

    /// What to stream, or `nil` for all of it.
    ///
    /// In points in the display's logical coordinate system, the space
    /// `SCStreamConfiguration.sourceRect` documents. `nil` is right for a source whose content
    /// is already exactly itself: a whole display, or a `desktopIndependentWindow` filter.
    let sourceRect: CGRect?
}

protocol CaptureSourceResolver: Sendable {
    /// Everything capturable right now, freshly enumerated if anything has changed.
    func catalog() async throws -> CaptureCatalog

    /// A content filter for one source, and how much of it to stream. Requires a prior
    /// ``catalog()`` call, see ``ScreenCaptureSourceResolver``.
    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan

    /// Where the source's content sits on screen, for mapping client input.
    func inputTransform(for source: CaptureSource) -> InputTransform

    /// Re-photographs the desktop showing on each display, ahead of the age check in
    /// ``ScreenCaptureSourceResolver/captureActiveSpacePreview(force:)``, for a client that is
    /// about to show the pictures.
    func refreshSpacePreviews() async

    /// Photographs each running application, for a client that is about to draw them.
    ///
    /// Asked for by ``RemoteCommand/refreshSourceThumbnails``. Unlike the previews above there
    /// is no schedule behind this and no age check: a grid of thumbnails is the only thing that
    /// draws one, and the client is the only end that knows one is on screen.
    func refreshSourceThumbnails() async

    /// The list may be out of date, and the next ``catalog()`` should enumerate again.
    ///
    /// No notification covers a window closing, so the capture noticing is the only way to find
    /// out. It also forgets which sources have been proved uncapturable, because a launch, a
    /// quit and a change of screen are all the machine changing under that answer. See
    /// ``markUncapturable(_:)``.
    func invalidate()

    /// A source this Mac has tried to capture and cannot, so the catalogue stops offering it.
    ///
    /// ScreenCaptureKit will list a window it will not render: its descriptor is as ordinary as
    /// any other, and a stream built for it starts and then delivers nothing. Nothing the
    /// enumeration says separates that window from a capturable one, so the evidence is a
    /// capture that produced no frame at all. See ``ScreenCaptureSourceResolver/uncapturable``.
    func markUncapturable(_ source: CaptureSource)

    /// A still of one source, at most `maxWidth` pixels across.
    ///
    /// A screenshot rather than a copy of a frame from the stream: those arrive on the queue the
    /// whole capture depends on, so reaching into it for a thumbnail would put this window's
    /// refresh rate in front of the phone's. `SCScreenshotManager` asks the window server for
    /// one picture instead, off that path entirely.
    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage?
}

/// The real resolver, backed by `SCShareableContent`.
///
/// A lock-guarded class rather than an actor: `SCShareableContent`, `SCContentFilter` and
/// `SCDisplay` are Objective-C types whose Swift overlay carries no `Sendable` annotations, so
/// handing them across an actor boundary is not something the compiler can check, and an actor
/// would force every call site into an `await` that buys no safety. The lock plus
/// `@unchecked Sendable` states the real invariant: this object serialises access to state that
/// is not safe to touch concurrently.
///
/// The catalogue is live, so rather than poll, this listens for the notifications that can
/// change the answer and marks the snapshot stale.
final class ScreenCaptureSourceResolver: CaptureSourceResolver, @unchecked Sendable {
    private let lock = NSLock()

    /// The last enumeration, kept because ``makeFilter(for:)`` has to be synchronous and
    /// needs the very same `SCWindow`/`SCDisplay` instances the catalogue was built from.
    private var snapshot: SCShareableContent?
    private var installedApplicationsCache: [InstalledApplicationDescriptor]?
    private var isStale = true

    /// When an enumeration with no window in it was first seen. See ``serve(_:)``.
    ///
    /// Nil whenever the last reading found a window, which is almost always. Under ``lock``.
    private var firstWindowlessReadAt: Date?

    /// How long readings with no window in them have to persist before one is believed.
    ///
    /// Several times the length of the Space change that produces them, and short enough that a Mac
    /// that really has nothing open is reported while the user is still looking at what they closed.
    private static let windowlessReadGrace: TimeInterval = 6
    private var observers: [NSObjectProtocol] = []

    /// What each desktop looked like the last time the host was on it. Keyed by Space ID, so a
    /// desktop keeps its picture when the ones around it are reordered or removed.
    private let spacePreviews = SpacePreviewCache()

    /// What each running application looked like when a client last asked. Keyed by
    /// ``CaptureSource/stableID``, so an application keeps its picture across the catalogue
    /// rebuilds that every other launch and quit causes.
    ///
    /// Nothing refreshes these on a schedule; they are taken when a client asks.
    private let sourceThumbnails = SourceThumbnailCache()

    /// Which Space each display was last seen showing.
    ///
    /// `NSWorkspace.activeSpaceDidChangeNotification` says only that a Space changed, so without
    /// this there is no way to tell a switch on the second screen from one on the first, and the
    /// only safe answer would be to photograph every display on every switch. Under ``lock``.
    private var lastActiveSpace: [UInt32: Int32] = [:]

    /// When each display's currently-active Space was last photographed.
    ///
    /// Windows are opened, moved and closed on the desktop being photographed constantly, and
    /// none of that announces itself, so a preview taken on arrival goes on describing a desktop
    /// that has changed underneath it. This is what lets ``captureActiveSpacePreview()`` re-shoot
    /// a desktop nobody has left. Under ``lock``.
    private var lastPreviewAt: [UInt32: DispatchTime] = [:]

    /// Looks for a Space change that no notification announced. See ``spacePollInterval``.
    private var spacePoll: Task<Void, Never>?

    /// How often to look for a Space change that nothing told us about.
    ///
    /// A switch on a second display can pass with no notification posted at all, so the
    /// notification is only the fast path and this is the one that is always right. Reading the
    /// Space lists is a couple of window-server calls and a screenshot only happens when
    /// something really changed, so the steady-state cost is the timer and nothing else.
    private static let spacePollInterval: Duration = .seconds(2)

    /// How long a preview of a desktop nobody has left stays good enough.
    ///
    /// Twelve seconds: long enough that a desktop being worked on is not photographed every
    /// couple of seconds, short enough that the picture in the desktops panel is recognisably of
    /// now. The cost is one screenshot per display per interval.
    private static let spacePreviewMaxAgeNanoseconds: UInt64 = 12 * 1_000_000_000

    /// Fired when the catalogue is known to be out of date: after an app launches or quits, or a
    /// display is added, removed or reconfigured. The host re-reads ``catalog()`` and pushes the
    /// result; pushing from inside the notification would be pushing from an unrelated thread.
    private let onInvalidate: (@Sendable () -> Void)?

    /// - Parameter onInvalidate: called off the main thread whenever the source list may
    ///   have changed. Optional so a one-shot probe can ignore it.
    init(onInvalidate: (@Sendable () -> Void)? = nil) {
        self.onInvalidate = onInvalidate
        registerObservers()

        // Photographed here rather than on the first catalogue: a desktop can only be captured
        // while it is on the display, and the catalogue is built on the client's schedule, so a
        // desktop visited before the client connected would otherwise have no picture.
        Task { [weak self] in await self?.captureActiveSpacePreview() }

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.spacePollInterval)
                guard !Task.isCancelled, let self else { return }
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
        // A source a capture has proved it cannot have is not offered at all: leaving it in gives
        // the phone a tile to draw and a window to open, and opening it does nothing. See
        // ``uncapturable``.
        let offTheList = lock.withLock { uncapturable }
        let descriptors = Self.descriptors(from: content).filter { !offTheList.contains($0.source) }
        let runningBundleIDs = Set(descriptors.compactMap(\.bundleIdentifier))
        let installed = lock.withLock { installedApplicationsCache }
            ?? Self.installedApplications()
        lock.withLock { installedApplicationsCache = installed }

        // Space info must be read on the main thread (CGS connection is thread-local).
        let spaceDisplays: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        // One display knows only its own Spaces, so the union of all of them decides which
        // pictures are worth keeping. Skipped when the read came back empty: an empty union is
        // indistinguishable from a failed read, and acting on it would throw away every picture
        // on the machine.
        if !spaceDisplays.isEmpty {
            spacePreviews.keep(only: Set(spaceDisplays.flatMap(\.ids)))
        }
        let spaceInfo = spaceDisplays.isEmpty ? nil : SpaceInfo(
            displays: spaceDisplays.map { display in
                // The desktops only. A fullscreen application's Space is left out of the count
                // and the previews, so the client is offered only places it can be sent. See
                // ``ManagedSpace``.
                SpaceDisplay(
                    displayID: display.displayID,
                    count: display.desktopIDs.count,
                    current: display.current,
                    previews: spacePreviews.previews(ids: display.desktopIDs)
                )
            }
        )

        // Said out loud when it happens: the cap is applied with `prefix` inside the catalogue,
        // so a machine over the limit loses the tail of an alphabetical list with no sign
        // anywhere, which reads as the picker being broken rather than as a bound being reached.
        let offered = installed.filter { !runningBundleIDs.contains($0.bundleIdentifier) }
        if offered.count > CaptureCatalog.maximumInstalledApplicationCount {
            resolverLog.notice("""
                \(offered.count, privacy: .public) installed applications found, \
                \(CaptureCatalog.maximumInstalledApplicationCount, privacy: .public) sent
                """)
        }

        // The displays and the windows, each with the picture the client last asked for. A row
        // with no picture carries none and the client draws its own outline, which is the honest
        // state both before anything has been taken and for a window the host could not
        // photograph.
        //
        // Applications carry none deliberately: their rows are icons on the client, which is what
        // an application's identity is.
        let pictured = descriptors.filter { $0.kind == .display || $0.kind == .window }
        // Pruned against what this build offers, so a picture outlives neither a display that was
        // unplugged nor a window that was closed. See ``SourceThumbnailCache/keep(only:)``.
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

    /// The snapshot, re-enumerated only when something has invalidated it.
    ///
    /// Two callers racing the first enumeration both enumerate: a duplicated round trip, not a
    /// correctness problem, and guarding it would mean holding a lock across an `await`.
    private func shareableContent() async throws -> SCShareableContent {
        if let cached = lock.withLock({ isStale ? nil : snapshot }) { return cached }

        let fresh: SCShareableContent
        do {
            // Desktop windows are excluded: capturing "the desktop" behind every window is not
            // something a user ever asks for, and it makes the window list enormous. The
            // enumeration stays this wide, and which windows may be offered to the phone is
            // decided in one place, in ``isUserFacingWindow(_:)``.
            fresh = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.from(error)
        }

        let (content, note) = lock.withLock { serve(fresh) }
        if let note { resolverLog.notice("\(note, privacy: .public)") }
        return content
    }

    /// Takes a reading as this Mac's windows, or serves the last one instead.
    ///
    /// **A reading with no window in it is not this Mac.** Every row the phone can be offered is
    /// built from a window: a window's row is the window, and an application's is the union of the
    /// windows it owns, so one reading with no window on any display is a picker with nothing in it,
    /// whichever way ScreenCaptureKit arrived at it. It arrives at it for a beat around a Space
    /// change, which is exactly when the phone is looking at the picker and asking for pictures, and
    /// believing the reading empties that picker for as long as the reading stays cached.
    ///
    /// So a first reading like this is not cached and the last good one is served in its place: the
    /// next caller looks again, and a Mac that really does have nothing open is believed once
    /// windowless readings ``windowlessReadGrace`` apart agree.
    ///
    /// Returns what to serve and, when there is something worth saying, the line to say about it.
    /// Under ``lock``, called with it held.
    private func serve(_ fresh: SCShareableContent) -> (SCShareableContent, String?) {
        guard Self.foundNoWindow(fresh) else {
            firstWindowlessReadAt = nil
            snapshot = fresh
            isStale = false
            return (fresh, nil)
        }

        let first = firstWindowlessReadAt ?? Date()
        let isFirstOfEpisode = firstWindowlessReadAt == nil
        firstWindowlessReadAt = first
        let doubtedFor = Date().timeIntervalSince(first)

        guard doubtedFor < Self.windowlessReadGrace else {
            snapshot = fresh
            isStale = false
            return (fresh, """
                no window on any display for \(Int(doubtedFor.rounded()))s; \
                taking the enumeration at its word
                """)
        }

        // Left out of date, so the next caller reads the window server instead of being handed
        // this reading straight back.
        isStale = true
        let serving = snapshot ?? fresh
        let note = isFirstOfEpisode
            ? "the enumeration found no window on any display, so the last listing stands until the next reading agrees"
            : nil
        return (serving, note)
    }

    /// Whether an enumeration came back with nothing the phone could be shown.
    ///
    /// Asked of the windows rather than of `applications`: an application with no window on a
    /// display has no row either, so the windows alone answer the question.
    private static func foundNoWindow(_ content: SCShareableContent) -> Bool {
        !content.windows.contains(where: isUserFacingWindow)
    }

    /// Marks the enumeration out of date without announcing it.
    ///
    /// ``invalidate()``'s first half, for a caller that is about to read ``shareableContent()``
    /// itself: the notification is what makes the host push a new catalogue, and a push that
    /// went out while this call was still working would arrive behind the one this call produces.
    private func markStale() {
        lock.withLock { isStale = true }
    }

    func invalidate() {
        let changed = lock.withLock { () -> Bool in
            let wasCurrent = !isStale
            isStale = true
            // A window that would not render may render now, and this is one of the few moments
            // that can be true. See ``uncapturable``.
            uncapturable = []
            return wasCurrent
        }
        guard changed else { return }
        resolverLog.debug("capture catalogue invalidated")
        onInvalidate?()
    }

    /// Sources a capture has proved this Mac cannot capture, by source.
    ///
    /// ScreenCaptureKit lists windows it will not render, and nothing in the enumeration
    /// separates one from a window that works: its descriptor is as ordinary as any other, and a
    /// stream built for it starts and then says nothing. The only evidence there is is a capture
    /// that produced no frame at all, and this is where a mosaic's report of one goes.
    ///
    /// Emptied by ``invalidate()``, which is a launch, a quit, a change of screen or a window
    /// changing size: all of them the machine changing under the answer. Under ``lock``.
    private var uncapturable: Set<CaptureSource> = []

    func markUncapturable(_ source: CaptureSource) {
        let fresh = lock.withLock { () -> Bool in
            isStale = true
            return uncapturable.insert(source).inserted
        }
        guard fresh else { return }
        resolverLog.notice("""
            \(source.stableID, privacy: .public) produced no picture when it was asked for one; \
            it is not being offered again
            """)
        // Announced rather than suppressed, unlike ``invalidate()``: the list really has changed,
        // and this is the push that takes the tile out of the phone's arrangement.
        onInvalidate?()
    }

    private func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        // Launch and terminate, not activate: switching to an already-running application
        // changes which windows are in front but adds nothing to capture. A window opened or
        // closed by a running application is covered by no notification, which is why the
        // windows in the catalogue carry the dimensions they had when it was built and why
        // ``makeFilter(for:)`` re-checks that the window still exists.
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

        // A Space change is deliberately not one of the names above: nothing about what can be
        // captured changed, so invalidating would cost a full re-enumeration of the shareable
        // content on every switch and buy nothing. What changed is which desktop is on the
        // display, and that is worth a photograph.
        let spaceObserver = workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.captureActiveSpacePreview() }
        }
        observers.append(spaceObserver)
    }

    // MARK: - Space previews

    /// How long a Space switch is given to finish on screen before that desktop is photographed.
    ///
    /// The notification arrives as the switch begins and the desktops then slide across the
    /// display. A shot taken during the slide is half of one desktop and half of the other, which
    /// the client would draw as a tile for the arriving Space.
    private static let spaceSwitchSettle: Duration = .milliseconds(900)

    /// Photographs the desktops that have just come to the front, so the client's picker has a
    /// tile for each.
    ///
    /// Driven by a Space changing rather than by anything a client asks for: a desktop in front
    /// is the only one ScreenCaptureKit can photograph, the rest being by definition on no
    /// display.
    ///
    /// The notification does not say which display changed, so this compares against the Space
    /// each display was last seen showing and photographs only the ones that differ. At startup
    /// that is every display, which puts a picture on the current desktop of each screen before
    /// the user has switched anything; afterwards it is one display, so one screenshot per switch
    /// however many screens the Mac has.
    ///
    /// Not called from ``catalog()``: a screenshot is a round trip through the window server and
    /// the catalogue is on the critical path of a client connecting. Everything here is
    /// best-effort, and a failure only costs a tile.
    func refreshSpacePreviews() async {
        await captureActiveSpacePreview(force: true)
    }

    /// Photographs every display and window the catalogue is offering, and files what it gets.
    ///
    /// Displays and windows, not applications: a picture is drawn for the two kinds of source
    /// that are a place and a plain icon for the two that are an identity.
    ///
    /// The same enumeration the catalogue is built from, so the pictures are of exactly the rows
    /// the client is looking at, including the filter that matters here: a window ScreenCaptureKit
    /// will not offer is not photographed.
    ///
    /// Concurrent and bounded, because every one of these is a round trip through the window
    /// server: all at once would put simultaneous captures on the hardware the live stream is
    /// already encoding on.
    ///
    /// A failure leaves the last picture alone rather than clearing it, since a nil here is also
    /// a capture that was refused or timed out, and the closed-window case is covered anyway by
    /// the prune in ``catalog()``.
    func refreshSourceThumbnails() async {
        // A fresh enumeration first, because this arrives when a client opens the picker, the one
        // place a stale list is visible as a fault. Window opens and closes inside a running
        // application post no notification at all, so a window made since the last push is
        // missing from the list the client is drawing and no amount of pushing fixes that from
        // the Mac's side. Re-reading costs one enumeration on an action the user has just taken
        // by hand, and it is what makes the picker show what is on the Mac now.
        markStale()
        guard let content = try? await shareableContent() else {
            resolverLog.notice("could not re-read the capture catalogue, so the picker is showing the last one")
            return
        }
        let sources = Self.descriptors(from: content)
            .filter { $0.kind == .display || $0.kind == .window }
            .map(\.source)
        guard !sources.isEmpty else { return }

        let landed = await withTaskGroup(
            of: (source: CaptureSource, thumbnail: SourceThumbnail?).self
        ) { group in
            var next = 0
            var stored = 0

            // Adds one more capture, or none when they have all been added. Called once for
            // each slot and then once per completion, which is what keeps the number in flight
            // at the limit without a semaphore.
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
                if let thumbnail = result.thumbnail {
                    self.sourceThumbnails.store(thumbnail, for: result.source)
                    stored += 1
                }
                addNext()
            }
            return stored
        }

        resolverLog.notice("""
            source thumbnails: \(landed, privacy: .public) of \
            \(sources.count, privacy: .public) photographed
            """)
        // The same signal a Space preview uses, and for the same reason: this is a change to the
        // catalogue that no notification about the source list covers. See ``previewLanded()``.
        previewLanded()
    }

    /// How many application screenshots may be in flight at once.
    ///
    /// Four, which photographs a typical Mac's worth of them in one round trip's time and is few
    /// enough that a large one cannot crowd out the live stream.
    private static let thumbnailConcurrency = 4

    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage? {
        // The same transform input is mapped through, which is the one thing here that already
        // knows how big a source is: a display's pixel dimensions, a window's frame times its
        // backing scale, an application's union of windows.
        let pixels = inputTransform(for: source).pixelSize
        guard pixels.width > 0, pixels.height > 0, maxWidth > 0 else { return nil }

        let scale = min(1, CGFloat(maxWidth) / pixels.width)
        let plan: CaptureFilterPlan
        do {
            plan = try makeFilter(for: source)
        } catch {
            // Said out loud, because nothing else does: a still that could not be taken is
            // indistinguishable from one that was never asked for, and the two have entirely
            // different causes, a capture problem against the ordinary state of the picker.
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
        // The same crop the stream uses, or a multi-window application would show its windows
        // sitting in the middle of a black frame here and nowhere else.
        if let sourceRect = plan.sourceRect {
            configuration.sourceRect = sourceRect
        }

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: plan.filter,
                configuration: configuration
            )
        } catch {
            resolverLog.notice("""
                snapshot of \(source.stableID, privacy: .public) was refused: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    /// Photographs the Space showing on each display, where that is worth doing.
    ///
    /// - Parameter force: ignore the age check and shoot anyway. For a client that has just
    ///   asked, because it is about to put the pictures in front of someone.
    func captureActiveSpacePreview(force: Bool = false) async {
        // Which displays want a new picture is decided before the settle, so a second
        // notification arriving during it does not get this call acting on a display it was never
        // about. Recorded here rather than after the captures, so one arriving mid-flight does
        // not queue the same display up twice.
        let before: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        let changed = lock.withLock { () -> [UInt32] in
            let now = DispatchTime.now()
            var due: [UInt32] = []
            for display in before {
                let arrived = lastActiveSpace[display.displayID] != display.activeID
                lastActiveSpace[display.displayID] = display.activeID

                // Aged out as well as arrived at: the desktop the user has been sitting on is the
                // one a client is most likely to be shown a picture of, and it is also the one
                // that goes most stale, since nothing announces a window opening on it.
                let age = lastPreviewAt[display.displayID].map {
                    now.uptimeNanoseconds - $0.uptimeNanoseconds
                } ?? .max

                if force || arrived || age >= Self.spacePreviewMaxAgeNanoseconds {
                    // Recorded at the decision rather than after the capture, so a capture that
                    // fails does not re-arm this to due on the next two-second tick.
                    lastPreviewAt[display.displayID] = now
                    due.append(display.displayID)
                }
            }
            return due
        }
        guard !changed.isEmpty else { return }

        try? await Task.sleep(for: Self.spaceSwitchSettle)

        // Read again after the settle, because a picture taken now is of whatever is on screen
        // now, and the read above can name a desktop the user has already left. Filing under that
        // one would put one desktop's picture under another desktop's name, which is the mistake
        // the ID-keyed cache exists to prevent.
        let settled: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        let targets = settled.filter { changed.contains($0.displayID) }
        guard !targets.isEmpty else { return }

        // Built from the cached enumeration rather than a fresh one: a Space switch does not
        // change which display a screenshot is taken of.
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            // Reported as itself and not as a missing display: this enumeration is where a host
            // without Screen Recording permission fails, and a log line blaming the hardware
            // sends the next reader looking at the wrong thing.
            resolverLog.notice("""
                space previews not captured: \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        var landed = false
        for display in targets {
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

            // Read after the shutter, which the read above is not the last word on: everything
            // in between, the enumeration and the capture itself, is time the person has to
            // switch again, and this is the only read that can say whether the picture is of the
            // desktop it is about to be filed under.
            //
            // Discarded rather than re-filed when they disagree: which of the two desktops the
            // picture caught is not a question a screenshot can be asked, and a tile that keeps
            // its older picture is a much smaller wrong than a tile showing a desktop it is not.
            let afterShutter: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
            guard afterShutter.first(where: { $0.displayID == display.displayID })?.activeID
                    == display.activeID
            else {
                resolverLog.notice("""
                    space \(display.activeID, privacy: .public) moved under the shutter; \
                    the preview is discarded rather than filed under the wrong desktop
                    """)
                continue
            }

            spacePreviews.store(shot, for: display.activeID)
            landed = true
        }
        guard landed else { return }

        previewLanded()
    }

    /// A preview has been captured, which is a change to the catalogue that no notification
    /// about the source list covers.
    ///
    /// It goes through `onInvalidate` because that is the established "the catalogue is out of
    /// date, read it again" signal, but not through ``invalidate()``: that one suppresses the
    /// call when the resolver is already stale, and a preview landing behind an unrelated launch
    /// would then never be pushed.
    private func previewLanded() {
        onInvalidate?()
    }

    /// The configuration a Space preview is photographed with.
    ///
    /// The height follows the display's own ratio instead of being fixed: `SCStreamConfiguration`
    /// preserves the aspect ratio by default, so a height that does not match leaves the desktop
    /// letterboxed inside its own thumbnail.
    private static func previewConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let width = SpacePreviewCache.pixelWidth
        // Points rather than pixels: only the ratio of the sides is needed here and both
        // accessors agree on it. A display that reports nothing at all gets a plausible shape,
        // because a zero height is a configuration ScreenCaptureKit rejects, not a small preview.
        let ratio = display.width > 0 && display.height > 0
            ? Double(display.height) / Double(display.width)
            : 10.0 / 16.0

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int((Double(width) * ratio).rounded()))
        // Nominal: the system composites at point resolution and scales to the size above. At
        // .best it would composite a full 6K surface per desktop and throw nearly all of it away
        // in the downscale, which is the entire cost of this call.
        configuration.captureResolution = .nominal
        // The live stream carries the cursor, because the client draws a pointer of its own
        // against it. A desktop thumbnail is a picture of a desktop, where a stray pointer is
        // one moment frozen for as long as the user stays on that Space.
        configuration.showsCursor = false
        return configuration
    }


    // MARK: - Descriptors

    private static func descriptors(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        // One icon encode per process for the whole catalogue, shared between an application's
        // own row and the rows of every window it owns: without the sharing, an app with six
        // windows open pays for the same PNG seven times on every rebuild, and the catalogue is
        // rebuilt on every launch and quit.
        var icons = ApplicationIcons()
        let displayRows = displays(from: content)
        let applicationRows = applications(from: content, icons: &icons)
        let windowRows = windows(from: content, icons: &icons)
        return displayRows + applicationRows + windowRows
    }

    /// The icons of the processes in one enumeration, encoded once each.
    ///
    /// Keyed by process rather than by bundle identifier, because that is the identity both
    /// `SCRunningApplication` and `SCWindow.owningApplication` hand out.
    ///
    /// A plain struct rather than the lock-guarded cache the Space previews use: this is a local
    /// of a single synchronous pass, so the lock would guard an audience of one.
    private struct ApplicationIcons {
        private var byProcess: [pid_t: Data?] = [:]

        /// The icon for one process, encoded on first ask.
        ///
        /// `nil` is a real answer, since a process may have no icon at all, so it is remembered
        /// as one rather than looked for again on every window that process owns.
        mutating func icon(for processID: pid_t) -> Data? {
            if let cached = byProcess.index(forKey: processID) {
                return byProcess[cached].value
            }
            let data = ScreenCaptureSourceResolver.applicationIcon(for: processID)
            byProcess[processID] = data
            return data
        }
    }

    /// An application's icon, preferring the running application's own.
    ///
    /// `NSRunningApplication.icon` can briefly be nil while an app is launching; the bundle icon
    /// is available earlier and is the same artwork users recognize in Finder.
    private static func applicationIcon(for processID: pid_t) -> Data? {
        guard let running = NSRunningApplication(processIdentifier: processID) else { return nil }
        if let data = iconPNGData(for: running) { return data }
        guard let bundleURL = running.bundleURL else { return nil }
        return iconPNGData(for: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    private static func displays(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.displays.compactMap { display in
            // `SCDisplay.width`/`height` are points, as the SDK header says, while the pixel
            // dimensions are what the normalised to pixel mapping needs. Using points there would
            // make the remote cursor drift further from the real one the further it is dragged.
            let pixelWidth = CGDisplayPixelsWide(display.displayID)
            let pixelHeight = CGDisplayPixelsHigh(display.displayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            return CaptureSourceDescriptor(
                kind: .display,
                title: screenName(for: display.displayID) ?? "Display \(display.displayID)",
                subtitle: "\(pixelWidth)×\(pixelHeight)",
                source: .display(display.displayID),
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                // Only a display the phone asked for. Every virtual display is that now; this is
                // what tells the client which rows it may rename and remove.
                isManagedVirtualDisplay: VirtualDisplay.isPhoneManaged(display.displayID),
                // The broader question: does this display exist only in software at all.
                // `VirtualDisplay.name(for:)` is non-nil for exactly that, because this process
                // names every display it makes — see the registry on ``VirtualDisplay``.
                isVirtualDisplay: VirtualDisplay.name(for: display.displayID) != nil
            )
        }
    }

    private static func applications(
        from content: SCShareableContent,
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var seenBundleIDs = Set<String>()
        var seenNames = Set<String>()
        var result: [CaptureSourceDescriptor] = []

        for application in content.applications {
            let running = NSRunningApplication(processIdentifier: application.processID)
            // ScreenCaptureKit includes agents, menu extras, and system surfaces. Only a
            // regular Dock application is meaningful in an app switcher.
            guard running?.activationPolicy == .regular else { continue }
            // A short list of the system's own surfaces, by identifier, rather than a check on
            // where a bundle lives: such a check excludes every Apple application, because
            // Terminal is under `/System/Applications` and Safari is in the App cryptex, reached
            // through a symlink in `/Applications` an enumerator will not follow. These three
            // each report a regular activation policy on some macOS versions and own surfaces
            // that are not windows a person means to capture.
            if let bundleIdentifier = running?.bundleIdentifier,
               Self.isSystemSurface(bundleIdentifier) {
                continue
            }

            let owned = content.windows.filter {
                $0.owningApplication?.processID == application.processID && isUserFacingWindow($0)
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
                // Not `application.applicationName` directly: it is empty for some processes, a
                // background agent or one that has not finished launching, and an unnamed row is
                // a blank cell in the client's picker that the user cannot identify or tell from
                // any other blank cell. The window case below refuses an empty title for the
                // same reason.
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
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var result: [CaptureSourceDescriptor] = []

        for window in content.windows {
            guard isUserFacingWindow(window) else { continue }
            guard let application = window.owningApplication, let bounds = unionFrame(of: [window]) else {
                continue
            }
            let running = NSRunningApplication(processIdentifier: application.processID)
            guard running?.activationPolicy == .regular else { continue }

            // A window with no title is usually a panel or a splash sheet. Naming it after
            // its application is more use than an empty cell in the picker.
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? application.applicationName
            let scale = backingScale(for: bounds)

            result.append(CaptureSourceDescriptor(
                kind: .window,
                title: title,
                subtitle: application.applicationName,
                bundleIdentifier: running?.bundleIdentifier,
                // The owning application's icon: a window has no icon of its own, and the icon is
                // what saves the user reading which application a picture belongs to.
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

    /// A user-selectable top-level window rather than a menu, shadow, desktop surface, or
    /// hidden bookkeeping surface an application keeps around for later.
    ///
    /// On screen, because a window that is not on screen is one nothing can be done with. Three
    /// ordinary cases are behind that: a window the application has closed but not released, a
    /// minimised one, and one on a Space this Mac is not showing. ScreenCaptureKit lists all
    /// three and renders none of them.
    private static func isUserFacingWindow(_ window: SCWindow) -> Bool {
        guard window.windowLayer == 0,
              window.isOnScreen,
              window.frame.width >= 1,
              window.frame.height >= 1
        else { return false }
        // **And by whose it is, which is the cause rather than the symptom.** The system's own
        // surfaces report a regular activation policy on some macOS versions and own windows that
        // look like any other; this is the same rule the application rows are filtered by, applied
        // here as well, because a window is not told apart from an application's window by anything
        // the enumeration says.
        if let bundleIdentifier = NSRunningApplication(
            processIdentifier: window.owningApplication?.processID ?? 0
        )?.bundleIdentifier, isSystemSurface(bundleIdentifier) {
            return false
        }
        return !isNamelessSurface(window)
    }

    /// Whether this is a window the system made for an application's own use rather than one a
    /// person is looking at.
    ///
    /// **The net under the rule that catches the ones that are named after a service.** Most
    /// nameless surfaces belong to a `<Name>UIService` process and are let go by
    /// ``isSystemSurface(_:)``; this is for the same shape coming from somewhere else, which is a
    /// surface a regular application made for itself and never titled.
    ///
    /// **The title is the only thing that identifies one, and the system's own word for "window" is
    /// the only title nobody ever means.** Such a surface is listed with everything else, it is
    /// photographed as a black rectangle, and a stream built for it either cannot be filtered or
    /// says nothing at all: a row in the phone's picker that does nothing when it is pressed, for as
    /// long as the two ends are connected. Traced from one: a Dictionary window titled "Window",
    /// black in the picker, unpressable, and impossible to tell from a real window by any field
    /// ``CaptureSourceDescriptor`` carries.
    ///
    /// **Matched as a set of words rather than by unit**, because a title is a string the system
    /// localises: the same surface is "Fenêtre" on a French Mac. Only the standalone word counts, so
    /// an application whose window is called "Window Manager" is left alone.
    private static func isNamelessSurface(_ window: SCWindow) -> Bool {
        guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return systemWindowTitles.contains(title.lowercased())
    }

    private static let systemWindowTitles: Set<String> = [
        "window", "fenêtre", "fenster", "ventana", "finestra", "venster", "okno", "ikkuna",
    ]

    /// Whether this bundle identifier belongs to the system rather than to a person's application.
    ///
    /// **Two rules, because the surfaces come in two shapes.** A short list of identifiers, for the
    /// ones this app has been caught by; and a name pattern, for a whole family nobody can
    /// enumerate: `<Name>UIService` is how the system names the little processes behind a lookup
    /// popover, a link preview and a share sheet, and they own windows with no name at all. Traced
    /// from one with ``Tools/CaptureProbe``: `LinkedNotesUIService`, a 254×254 window titled
    /// "Window" on layer 25, listed with every other window and indistinguishable from one a person
    /// is looking at. On the phone it was a row under the application's own name that photographed
    /// as a black rectangle and did nothing when it was pressed. See ``isNamelessSurface(_:)`` for
    /// the belt to this pair of braces.
    private static func isSystemSurface(_ bundleIdentifier: String) -> Bool {
        systemSurfaces.contains(bundleIdentifier) || bundleIdentifier.hasSuffix("UIService")
    }

    /// The system's own surfaces: regular by activation policy, and not applications.
    ///
    /// See the note at the call site for why this is a list of identifiers rather than a check on
    /// where a bundle lives.
    private static let systemSurfaces: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.wallpaper.agent",
        "com.apple.WindowManager",
    ]

    private static func installedApplications() -> [InstalledApplicationDescriptor] {
        // The system domain is where Apple's own applications are: Terminal and its neighbours
        // are under `/System/Applications`, and Safari is in the App cryptex, which the system
        // domain resolves to and a symlink in `/Applications` does not lead an enumerator to.
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

    /// Downsamples before PNG encoding. A bundle's original 1024-point icon would make a small
    /// picker row need megabytes of control-channel data.
    ///
    /// 128 pixels: the picker's grid shows an icon at 74 points and a phone draws that at three
    /// times the pixels, so the previous 48-pixel icon was stretched nearly five times over and
    /// read as a blurred square rather than as the application's own artwork.
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

    /// The bounding box of a set of windows, or `nil` if none has a usable frame.
    ///
    /// An empty or degenerate frame means a window that is minimised or fully off-screen.
    /// Capturing one yields a stream of nothing, and its zero size would divide by zero in
    /// the coordinate mapping.
    private static func unionFrame(of windows: [SCWindow]) -> CGRect? {
        let frames = windows.map(\.frame).filter { $0.width >= 1 && $0.height >= 1 }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
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
            // Excluding rather than including windows: the empty exclusion list captures the
            // Excluding rather than including windows: the empty exclusion list captures the
            // whole display and the desktop and menu bar behind it, which is what "share my
            // screen" means.
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

            // A single window can be captured independently of the display it sits on, which
            // produces a frame exactly the window size with no surrounding black space. With
            // several windows a display-relative filter is the only option, and the
            // configuration's sourceRect crops the output to their bounding box; otherwise the
            // whole display is streamed with the non-app content blacked out, giving the iPhone a
            // large black canvas with a small app somewhere inside it.
            if owned.count == 1 {
                // Already exactly the window, with no surround left to crop away.
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
            // Desktop-independent, so the window keeps being captured when it is covered by
            // another window or dragged to a different display. A display filter that includes
            // this one window would capture whatever is drawn on top of it.
            return CaptureFilterPlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil
            )

        case .mosaic:
            // Reachable only by mistake: a mosaic is captured as one filter per tile, and each
            // of those comes through the cases above as the source it names. There is no filter
            // for the canvas, because nothing on the Mac shows a canvas, so a sentence is better
            // than the black picture the caller would otherwise get.
            throw CaptureError.sourceUnavailable(
                "A mosaic is composited from its tiles rather than captured in one piece."
            )
        }
    }

    /// A bounding box in global points, expressed in the display's own coordinate space.
    ///
    /// `SCWindow.frame` is in global display points, the space `CGEvent` posts into, where a
    /// display left of the primary has a negative origin, while `SCStreamConfiguration.sourceRect`
    /// is documented as being in the display's logical coordinate system, which starts at that
    /// display's own top-left. Passing one where the other is wanted crops a plausible-looking
    /// rectangle off the wrong part of the screen.
    ///
    /// Clamped to the display afterwards, because an app whose windows hang off the edge asks for
    /// a rectangle partly outside it, and a crop the stream cannot honour fails rather than being
    /// trimmed.
    private static func sourceRect(for union: CGRect, on display: SCDisplay) -> CGRect? {
        // `display.frame` is points; `display.width`/`height` are pixels. Both sides of this
        // intersection have to be points, or a Retina display halves the crop.
        let local = union.offsetBy(
            dx: -display.frame.origin.x,
            dy: -display.frame.origin.y
        )
        let within = local.intersection(CGRect(origin: .zero, size: display.frame.size))
        return within.isNull || within.isEmpty ? nil : within
    }

    /// The display a rect sits on, falling back to the first one enumerated.
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

    /// Where the source's content is, in the global point space `CGEvent` posts into.
    ///
    /// The same mapping ``DisplayGeometry`` builds for displays, re-derived here because all three
    /// kinds of source have to answer the question the same way.
    ///
    /// Built from catalogue-time geometry: a window dragged or resized moves without any
    /// notification being posted, so this goes stale the moment the user touches it. The
    /// authoritative answer arrives per frame, in the content rect `CaptureEngine` reports, and
    /// the input layer is expected to prefer that.
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
            // There is no point in a mosaic for a click to be at: the tile under it decides
            // which machine coordinate it means, and a tile is chosen in the app rather than
            // posted at the Mac. A degenerate transform is the honest answer, and the host
            // refuses input outright while a mosaic is the source. See ``VideoCoordinator``'s
            // input guard.
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

    /// The backing scale of the display a rect is on: 2.0 on a Retina panel, but also the
    /// odd ratios a 4K display at a scaled resolution produces.
    private static func backingScale(for rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 16, &ids, &count) == .success, count > 0 else { return 1 }

        let bounds = CGDisplayBounds(ids[0])
        guard bounds.width > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(ids[0])) / bounds.width
    }

    /// The user-facing name of a display, e.g. "Built-in Retina Display".
    ///
    /// `NSScreen` is the only source of these names; CoreGraphics reports a model number, not a
    /// name. A panel that has no `NSScreen`, including the virtual display the host made itself,
    /// which AppKit never adopts, falls back to the name this process gave it and then to its
    /// identifier. See ``VirtualDisplay/name(for:)``.
    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
        return screen?.localizedName ?? VirtualDisplay.name(for: displayID)
    }
}

extension InputTransform {
    /// What a source that has gone away maps to.
    ///
    /// Zero-sized rather than `nil` because ``InputTransform`` is not optional in
    /// ``CaptureSourceResolver`` and a throwing accessor would force every caller to handle a
    /// case that cannot happen: capture never starts for a source that is not in the catalogue.
    static let degenerate = InputTransform(origin: .zero, pixelSize: .zero, pointPixelScale: 1)
}
