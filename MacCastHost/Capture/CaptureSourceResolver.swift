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
/// The protocol exists so the pipeline never talks to ScreenCaptureKit directly. Nothing in
/// the host can be tested on a machine without Screen Recording permission — which includes
/// most CI — so the seam is there to let a future test drive the pipeline with a fake
/// catalogue rather than to be swapped for a second real implementation.
/// A filter for a capture source, and the region of it worth streaming.
///
/// The two travel together because they are only correct as a pair. The rectangle is expressed
/// in the *filter's* coordinate space, so a caller that took one without the other would crop
/// the wrong part of the wrong thing — and would do it silently.
struct CaptureFilterPlan {
    let filter: SCContentFilter

    /// What to stream, or `nil` for all of it.
    ///
    /// In points in the display's logical coordinate system, which is the space
    /// `SCStreamConfiguration.sourceRect` documents. `nil` is the right answer for every source
    /// whose content is already exactly itself: a whole display, or a `desktopIndependentWindow`
    /// filter that has already isolated one window with no surround to crop away.
    let sourceRect: CGRect?
}

protocol CaptureSourceResolver: Sendable {
    /// Everything capturable right now, freshly enumerated if anything has changed.
    func catalog() async throws -> CaptureCatalog

    /// A content filter for one source, and how much of it to stream. Requires a prior
    /// ``catalog()`` call — see ``ScreenCaptureSourceResolver``.
    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan

    /// Where the source's content sits on screen, for mapping client input.
    func inputTransform(for source: CaptureSource) -> InputTransform

    /// Re-photographs the desktop showing on each display, ahead of the schedule the age check
    /// in ``ScreenCaptureSourceResolver/captureActiveSpacePreview(force:)`` would otherwise keep
    /// to. Asked for by a client that is about to show the pictures.
    func refreshSpacePreviews() async

    /// A still of one source, at most `maxWidth` pixels across.
    ///
    /// A screenshot rather than a copy of a frame from the stream. The stream's frames are the
    /// real thing, but they arrive on the queue the whole capture depends on, and reaching into
    /// it to make a thumbnail would put this window's refresh rate in front of the phone's.
    /// `SCScreenshotManager` asks the window server for one picture instead, off that path
    /// entirely.
    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage?
}

/// The real resolver, backed by `SCShareableContent`.
///
/// **This is a lock-guarded class rather than an actor, and that is not a style choice.**
/// `SCShareableContent`, `SCContentFilter` and `SCDisplay` are Objective-C types from a
/// module whose Swift overlay is built with `-swift-version 5` and carries no `Sendable`
/// annotations at all — verified in the SDK's `ScreenCaptureKit.swiftinterface`, which is
/// 34 lines long and mentions neither `Sendable` nor `nonisolated`. Handing them across an
/// actor boundary is therefore not something the compiler can check, and an actor would
/// force every call site into an `await` that buys no safety. The lock plus
/// `@unchecked Sendable` states the real invariant: this object serialises access to state
/// that is not safe to touch concurrently, and nothing here blocks for long enough to be
/// worth suspending over.
///
/// The catalogue is *live*. Sources appear and disappear while the host window is open — a
/// display is plugged in, an application quits — and a picker showing a stale list offers
/// the user things that cannot be captured. Rather than poll, this listens for the four
/// notifications that can change the answer and marks the snapshot stale.
final class ScreenCaptureSourceResolver: CaptureSourceResolver, @unchecked Sendable {
    private let lock = NSLock()

    /// The last enumeration, kept because ``makeFilter(for:)`` has to be synchronous and
    /// needs the very same `SCWindow`/`SCDisplay` instances the catalogue was built from.
    private var snapshot: SCShareableContent?
    private var installedApplicationsCache: [InstalledApplicationDescriptor]?
    private var isStale = true
    private var observers: [NSObjectProtocol] = []

    /// What each desktop looked like the last time the host was on it. Keyed by Space ID, so a
    /// desktop keeps its picture when the user reorders or removes the ones around it — see
    /// ``orderedSpacePreviews(ids:activeID:shots:)``.
    private let spacePreviews = SpacePreviewCache()

    /// Which Space each display was last seen showing.
    ///
    /// `NSWorkspace.activeSpaceDidChangeNotification` says only that *a* Space changed, so
    /// without this there is no way to tell a switch on the second screen from one on the first,
    /// and the only safe answer would be to photograph every display on every switch.
    /// Under ``lock`` with the rest of the mutable state.
    private var lastActiveSpace: [UInt32: Int32] = [:]

    /// When each display's currently-active Space was last photographed.
    ///
    /// A Space *switch* is not the only thing that makes a preview wrong. Windows are opened,
    /// moved and closed on the desktop being photographed constantly, and not one of those
    /// announces itself — so a preview taken when the user arrived stays on screen describing
    /// a desktop that has since changed underneath it. This is what lets
    /// ``captureActiveSpacePreview()`` re-shoot a desktop nobody has left. Under ``lock`` with
    /// the rest of the mutable state.
    private var lastPreviewAt: [UInt32: DispatchTime] = [:]

    /// Looks for a Space change that no notification announced. See ``spacePollInterval``.
    private var spacePoll: Task<Void, Never>?

    /// How often to look for a Space change that nothing told us about.
    ///
    /// The notification is the fast path and this is the one that is always right: a switch on a
    /// second display can pass with no notification posted at all, and did — the host log showed
    /// two previews after launch and one more for the rest of the session, with whole desktops
    /// never photographed while their neighbours were. Reading the Space lists is a couple of
    /// window-server calls and a comparison, and a screenshot only happens when something really
    /// did change, so the steady-state cost of this is the timer and nothing else.
    private static let spacePollInterval: Duration = .seconds(2)

    /// How long a preview of a desktop nobody has left stays good enough.
    ///
    /// The poll above runs every two seconds and exists to catch a Space change no notification
    /// announced; this is the other half of the same question, and the one a user actually
    /// notices. Twelve seconds is a compromise: long enough that a desktop being worked on is
    /// not photographed every couple of seconds for no reason, short enough that the picture in
    /// the desktops panel is recognisably of now. The cost is one screenshot per display per
    /// interval — a round trip through the window server, but nothing near the video path's.
    private static let spacePreviewMaxAgeNanoseconds: UInt64 = 12 * 1_000_000_000

    /// Fired when the catalogue is known to be out of date — after an app launches or quits,
    /// or a display is added, removed or reconfigured. The host re-reads ``catalog()`` and
    /// pushes the result; pushing from inside the notification would mean pushing from a
    /// thread that has nothing to do with the session.
    private let onInvalidate: (@Sendable () -> Void)?

    /// - Parameter onInvalidate: called off the main thread whenever the source list may
    ///   have changed. Optional so a one-shot probe can ignore it.
    init(onInvalidate: (@Sendable () -> Void)? = nil) {
        self.onInvalidate = onInvalidate
        registerObservers()

        // The desktop the host is on is photographed once here rather than on the first
        // catalogue. A desktop can only be captured while it is on the display, the catalogue
        // is built on the client's schedule rather than the user's, and the whole point of the
        // cache is that a desktop visited before the client connected still has a picture.
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
        let descriptors = Self.descriptors(from: content)
        let runningBundleIDs = Set(descriptors.compactMap(\.bundleIdentifier))
        let installed = lock.withLock { installedApplicationsCache }
            ?? Self.installedApplications()
        lock.withLock { installedApplicationsCache = installed }

        // Space info must be read on the main thread (CGS connection is thread-local).
        let spaceDisplays: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        // One display knows only its own Spaces, so the union of all of them is what decides
        // which pictures are still worth keeping. Skipped when the read came back empty: an empty
        // union is indistinguishable from "the window server did not answer this time", and
        // acting on it would throw away every picture on the machine over one failed read.
        if !spaceDisplays.isEmpty {
            spacePreviews.keep(only: Set(spaceDisplays.flatMap(\.ids)))
        }
        let spaceInfo = spaceDisplays.isEmpty ? nil : SpaceInfo(
            displays: spaceDisplays.map { display in
                // The desktops only. A fullscreen application's Space is left out of both the
                // count and the previews, so the client is offered only places it can actually
                // be sent — see ``ManagedSpace``.
                SpaceDisplay(
                    displayID: display.displayID,
                    count: display.desktopIDs.count,
                    current: display.current,
                    previews: spacePreviews.previews(ids: display.desktopIDs)
                )
            }
        )

        return CaptureCatalog(
            displays: descriptors.filter { $0.kind == .display },
            applications: descriptors.filter { $0.kind == .application },
            windows: descriptors.filter { $0.kind == .window },
            installedApplications: installed.filter { !runningBundleIDs.contains($0.bundleIdentifier) },
            spaceInfo: spaceInfo
        )
    }

    /// The snapshot, re-enumerated only when something has invalidated it.
    ///
    /// Two callers racing the first enumeration will both enumerate; that is a duplicated
    /// round trip, not a correctness problem, and guarding it would mean holding a lock
    /// across an `await`.
    private func shareableContent() async throws -> SCShareableContent {
        if let cached = lock.withLock({ isStale ? nil : snapshot }) { return cached }

        let fresh: SCShareableContent
        do {
            // Desktop windows are excluded because capturing "the desktop" behind every
            // window is not something a user ever asks for, and it makes the window list
            // enormous. On-screen only, because an off-screen window composites to nothing
            // and offering it would produce a stream of empty black frames.
            fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.from(error)
        }

        lock.withLock {
            snapshot = fresh
            isStale = false
        }
        return fresh
    }

    private func invalidate() {
        let changed = lock.withLock { () -> Bool in
            let wasCurrent = !isStale
            isStale = true
            return wasCurrent
        }
        guard changed else { return }
        resolverLog.debug("capture catalogue invalidated")
        onInvalidate?()
    }

    private func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        // Launch and terminate, not activate: switching to an already-running application
        // changes which windows are in front but adds nothing to capture. A window that is
        // opened or closed by a running application is *not* covered by any notification,
        // which is why the windows in the catalogue carry the dimensions they had when it
        // was built and why ``makeFilter(for:)`` re-checks that the window still exists.
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

        // A Space change is deliberately *not* one of the names above. Nothing about what can
        // be captured changed, so invalidating would cost a full re-enumeration of the
        // shareable content on every switch and buy nothing; what changed is which desktop is
        // on the display, and that is worth a photograph.
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
    /// display. A shot taken during the slide is half of one desktop and half of the other,
    /// which the client would draw as a tile for the arriving Space — a wrong picture, where
    /// waiting a moment only makes it a later one.
    private static let spaceSwitchSettle: Duration = .milliseconds(900)

    /// Photographs the desktops that have just come to the front, so the client's picker has a
    /// tile for each.
    ///
    /// Driven by a Space changing rather than by anything a client asks for, because a desktop in
    /// front is the only one ScreenCaptureKit can photograph — the rest are, by definition, not
    /// on any display.
    ///
    /// The notification does not say *which* display changed, so this compares against the Space
    /// each display was last seen showing and photographs only the ones that differ. At startup
    /// that is every display, which is what puts a picture on the current desktop of each screen
    /// before the user has switched anything; afterwards it is one display, so one screenshot per
    /// switch however many screens the Mac has.
    ///
    /// **It is not called from ``catalog()``.** A screenshot is a round trip through the window
    /// server, and the catalogue is on the critical path of a client connecting: a preview is
    /// worth a task of its own and a push of its own, and never a millisecond of the
    /// catalogue's. Everything here is best-effort, and a failure only costs a tile.
    func refreshSpacePreviews() async {
        await captureActiveSpacePreview(force: true)
    }

    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage? {
        // The same transform input is mapped through, which is the one thing in this file that
        // already knows how big a source is — a display's pixel dimensions, a window's frame
        // times its backing scale, an application's union of windows.
        let pixels = inputTransform(for: source).pixelSize
        guard pixels.width > 0, pixels.height > 0, maxWidth > 0 else { return nil }

        let scale = min(1, CGFloat(maxWidth) / pixels.width)
        let plan: CaptureFilterPlan
        do {
            plan = try makeFilter(for: source)
        } catch {
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

        return try? await SCScreenshotManager.captureImage(
            contentFilter: plan.filter,
            configuration: configuration
        )
    }

    /// Photographs the Space showing on each display, where that is worth doing.
    ///
    /// - Parameter force: ignore the age check and shoot anyway. For a client that has just
    ///   asked, because it is about to put the pictures in front of someone.
    func captureActiveSpacePreview(force: Bool = false) async {
        // Which displays want a new picture is decided *before* the settle, so a second
        // notification arriving during it does not get this call acting on a display it was never
        // about. Recorded here rather than after the captures, so a notification arriving
        // mid-flight does not queue the same display up twice.
        let before: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        let changed = lock.withLock { () -> [UInt32] in
            let now = DispatchTime.now()
            var due: [UInt32] = []
            for display in before {
                let arrived = lastActiveSpace[display.displayID] != display.activeID
                lastActiveSpace[display.displayID] = display.activeID

                // Aged out as well as arrived at. A desktop the user has been sitting on is
                // exactly the one a client is most likely to be shown a picture of, and it is
                // also the one that goes most stale — nothing announces a window opening on it.
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

        // Read *again* after the settle, because a picture taken now is of whatever is on screen
        // now — and the read above can name a desktop the user has already left. Filing under
        // that one would put one desktop's picture under another desktop's name, which is the
        // mistake the ID-keyed cache exists to prevent.
        //
        // This used to be handled by discarding the shot whenever the user had moved on, which
        // threw away most of the pictures from anyone switching quickly. Re-reading makes the
        // question go away instead of answering it.
        let settled: [ManagedDisplay] = await MainActor.run { readDisplaySpaces() }
        let targets = settled.filter { changed.contains($0.displayID) }
        guard !targets.isEmpty else { return }

        // Built from the cached enumeration rather than a fresh one: the display a screenshot
        // is taken of is not something a Space switch changes.
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            // Reported as itself and not as a missing display. This enumeration is where a host
            // without Screen Recording permission fails, and a log line blaming the hardware
            // sends the next person to read it looking at the wrong thing entirely.
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

            // Read *after* the shutter, which the read above is not the last word on. Everything
            // between them — the enumeration, the capture itself — is time the person has to
            // switch again, and while the picture waits here nobody has checked which desktop it
            // caught. The read above answers "where was the display when we decided to shoot";
            // this one is the only thing that can answer "is this picture of the desktop it is
            // about to be filed under".
            //
            // Discarded rather than re-filed when they disagree. Which of the two desktops the
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
    /// call when the resolver is already stale, and a preview landing behind an unrelated
    /// application launch would then never be pushed — leaving the client with an empty tile
    /// until something else happened to rebuild the catalogue.
    private func previewLanded() {
        onInvalidate?()
    }

    /// The configuration a Space preview is photographed with.
    ///
    /// The height follows the display's own ratio instead of being fixed. `SCStreamConfiguration`
    /// preserves the aspect ratio by default, so a height that does not match leaves the
    /// desktop letterboxed inside its own thumbnail — and a preview that misplaces the content
    /// is worse than no preview, because the client offers it as a picture of where things are.
    private static func previewConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let width = SpacePreviewCache.pixelWidth
        // Points rather than pixels: the only thing needed here is the ratio of the sides, and
        // both accessors agree on it. A display that reports nothing at all gets a plausible
        // shape, because a zero height is not a small preview — it is a configuration
        // ScreenCaptureKit rejects without saying which field was wrong.
        let ratio = display.width > 0 && display.height > 0
            ? Double(display.height) / Double(display.width)
            : 10.0 / 16.0

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int((Double(width) * ratio).rounded()))
        // Nominal: the system composites at point resolution and scales to the size above. At
        // .best it would composite a full 6K surface per desktop and throw nearly all of it
        // away in the downscale, which is the entire cost of this call.
        configuration.captureResolution = .nominal
        // The live stream carries the cursor, because the client draws a pointer of its own
        // against it. A desktop thumbnail is a picture of a desktop: a stray pointer in it is
        // one moment frozen for as long as the user stays on that Space.
        configuration.showsCursor = false
        return configuration
    }


    // MARK: - Descriptors

    private static func descriptors(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        // One icon encode per process for the whole catalogue, shared between an application's
        // own row and the rows of every window it owns. Without the sharing, an application
        // with six windows open pays for the same PNG seven times on every rebuild — and the
        // catalogue is rebuilt on every application launch and quit.
        var icons = ApplicationIcons()
        let displayRows = displays(from: content)
        let applicationRows = applications(from: content, icons: &icons)
        let windowRows = windows(from: content, icons: &icons)
        return displayRows + applicationRows + windowRows
    }

    /// The icons of the processes in one enumeration, encoded once each.
    ///
    /// Keyed by process rather than by bundle identifier because that is the identity both
    /// `SCRunningApplication` and `SCWindow.owningApplication` hand out, so it is the one
    /// lookup that needs no second source of truth to agree with.
    ///
    /// A plain struct and not the lock-guarded cache the Space previews use: this one is a
    /// local of a single synchronous pass, so the lock would guard an audience of one.
    private struct ApplicationIcons {
        private var byProcess: [pid_t: Data?] = [:]

        /// The icon for one process, encoded on first ask.
        ///
        /// `nil` is a real answer — a process may have no icon at all — so it is remembered as
        /// one rather than looked for again on every window that process owns.
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
    /// `NSRunningApplication.icon` can briefly be nil while an app is launching. The bundle
    /// icon is available earlier and is the same artwork users recognize in Finder.
    private static func applicationIcon(for processID: pid_t) -> Data? {
        guard let running = NSRunningApplication(processIdentifier: processID) else { return nil }
        if let data = iconPNGData(for: running) { return data }
        guard let bundleURL = running.bundleURL else { return nil }
        return iconPNGData(for: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    private static func displays(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.displays.compactMap { display in
            // `SCDisplay.width`/`height` are **points** — the SDK header says so outright —
            // while the pixel dimensions are what the normalised→pixel mapping needs. On a
            // 5K panel the two differ by a factor of two, and using points there would make
            // the remote cursor drift further from the real one the further it is dragged.
            let pixelWidth = CGDisplayPixelsWide(display.displayID)
            let pixelHeight = CGDisplayPixelsHigh(display.displayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            return CaptureSourceDescriptor(
                kind: .display,
                title: screenName(for: display.displayID) ?? "Display \(display.displayID)",
                subtitle: "\(pixelWidth)×\(pixelHeight)",
                source: .display(display.displayID),
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight)
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
            // System processes in /System/ sometimes slip through the activation-policy
            // check on certain macOS versions (Wallpaper, Control Center, WindowManager…).
            // A bundle that lives on the sealed system volume is never something the user
            // would want to capture by name.
            if let bundlePath = running?.bundleURL?.path, bundlePath.hasPrefix("/System/") {
                continue
            }

            let owned = content.windows.filter { $0.owningApplication?.processID == application.processID }
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
                // Not `application.applicationName` directly. It is empty for some
                // processes — a background agent, or one that has not finished launching —
                // and an unnamed row is a blank cell in the client's picker that the user
                // cannot identify or distinguish from any other blank cell. The window case
                // below already refuses to emit an empty title for the same reason; this is
                // the same rule, and it was simply missing here.
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
    /// ScreenCaptureKit's own name is preferred because it is what the application calls
    /// itself. The fallbacks go through `NSRunningApplication` — the same source the rest of
    /// macOS uses for "the app with this pid" — and only then give up and name it by pid.
    /// The pid is the identity the client will send back, so it is never wrong, just less
    /// readable; an empty string, by contrast, is unusable.
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
                // The owning application's icon. A window has no icon of its own, and the
                // generic window glyph this row used to fall back to sat beside the
                // application's *name* — leaving the user to read which application a picture
                // belongs to, which is the one job an icon is there to do without reading.
                iconPNGData: icons.icon(for: application.processID),
                source: .window(window.windowID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            ))
        }

        return result
    }

    /// Enumerates top-level GUI application bundles, excluding Apple's sealed system apps.
    /// Package descendants are skipped so helper tools inside an app never become rows.
    private static func installedApplications() -> [InstalledApplicationDescriptor] {
        let roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask]
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

    /// Downsamples before PNG encoding. Sending an app bundle's original 1024-point icon
    /// would make a small picker row need megabytes of control-channel data.
    private static func iconPNGData(for icon: NSImage) -> Data? {
        let dimension = 48
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
            // whole display *and* the desktop and menu bar behind it, which is what "share my
            // screen" means. An including filter would capture only the listed windows over
            // an empty backdrop.
            // The whole display, which is what this source means.
            return CaptureFilterPlan(
                filter: SCContentFilter(display: display, excludingWindows: []),
                sourceRect: nil
            )

        case .application(let pid):
            guard let application = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.sourceUnavailable("That application is no longer running.")
            }
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid
                && $0.frame.width >= 1
                && $0.frame.height >= 1
            }
            guard !owned.isEmpty else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }

            // A single window can be captured independently of the display it sits on, which
            // produces a frame that is exactly the window size with no surrounding black space.
            // When the app has multiple windows a display-relative filter is the only SCK
            // option, and the configuration's sourceRect is set to crop the output to the
            // bounding box of those windows — otherwise the entire display is streamed with
            // non-app content blacked out, giving the iPhone a large black canvas with a
            // small app somewhere inside it.
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
            // another window or dragged to a different display. The alternative — a display
            // filter that includes this one window — captures whatever is drawn on top of it.
            return CaptureFilterPlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil
            )
        }
    }

    /// A bounding box in global points, expressed in the display's own coordinate space.
    ///
    /// This conversion is the whole reason the crop rectangle is easy to get wrong. `SCWindow.frame`
    /// is in *global* display points — the space `CGEvent` posts into, where a display left of the
    /// primary has a negative origin — while `SCStreamConfiguration.sourceRect` is documented as
    /// being in *the display's logical coordinate system*, which starts at that display's own
    /// top-left. So the two differ by the display's origin, and passing one where the other is
    /// wanted crops a plausible-looking rectangle off the wrong part of the screen.
    ///
    /// Clamped to the display afterwards, because an app whose windows hang off the edge asks for
    /// a rectangle that is partly outside it, and a crop the stream cannot honour is a crop that
    /// fails rather than one that is trimmed.
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
    /// This is the same mapping ``DisplayGeometry`` builds for displays, re-derived here
    /// because displays are only one of three kinds of source and all three have to answer
    /// the question the same way. Application and window sources need the union of their
    /// frames and the backing scale of whichever display they are on.
    ///
    /// **It is built from catalogue-time geometry.** A window that is dragged or resized
    /// moves without any notification being posted, so this goes stale the moment the user
    /// touches the window. The authoritative answer arrives per frame, in the content rect
    /// `CaptureEngine` reports, and the input layer is expected to prefer that.
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
    /// `NSScreen` is the only source of these names — CoreGraphics reports a model number,
    /// not a name. A panel that has no `NSScreen` (an unusual configuration, or a headless
    /// process that never brought up AppKit) falls back to its identifier.
    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }?.localizedName
    }
}

extension InputTransform {
    /// What a source that has gone away maps to.
    ///
    /// Zero-sized rather than `nil` because ``InputTransform`` is not optional in
    /// ``CaptureSourceResolver`` and a throwing accessor would force every caller to handle
    /// a case that cannot happen: capture never starts for a source that is not in the
    /// catalogue, so no client coordinate is ever mapped through this.
    static let degenerate = InputTransform(origin: .zero, pixelSize: .zero, pointPixelScale: 1)
}
