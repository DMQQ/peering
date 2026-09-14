import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let resolverLog = Logger(subsystem: "pl.dmq.maccast.host", category: "capture")

/// Answers the three questions the rest of the pipeline has about capture sources: what can
/// be captured, how to configure a stream for one of them, and where that content sits on
/// screen so client coordinates can be mapped into it.
///
/// The protocol exists so the pipeline never talks to ScreenCaptureKit directly. Nothing in
/// the host can be tested on a machine without Screen Recording permission — which includes
/// most CI — so the seam is there to let a future test drive the pipeline with a fake
/// catalogue rather than to be swapped for a second real implementation.
protocol CaptureSourceResolver: Sendable {
    /// Everything capturable right now, freshly enumerated if anything has changed.
    func catalog() async throws -> [CaptureSourceDescriptor]

    /// A content filter for one source. Requires a prior ``catalog()`` call — see
    /// ``ScreenCaptureSourceResolver``.
    func makeFilter(for source: CaptureSource) throws -> SCContentFilter

    /// Where the source's content sits on screen, for mapping client input.
    func inputTransform(for source: CaptureSource) -> InputTransform
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
    private var isStale = true
    private var observers: [NSObjectProtocol] = []

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
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Catalogue

    func catalog() async throws -> [CaptureSourceDescriptor] {
        let content = try await shareableContent()
        return Self.descriptors(from: content)
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
    }

    // MARK: - Descriptors

    private static func descriptors(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        displays(from: content) + applications(from: content) + windows(from: content)
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

    private static func applications(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.applications.compactMap { application in
            let owned = content.windows.filter { $0.owningApplication?.processID == application.processID }
            guard let bounds = unionFrame(of: owned) else { return nil }

            let scale = backingScale(for: bounds)
            return CaptureSourceDescriptor(
                kind: .application,
                // Not `application.applicationName` directly. It is empty for some
                // processes — a background agent, or one that has not finished launching —
                // and an unnamed row is a blank cell in the client's picker that the user
                // cannot identify or distinguish from any other blank cell. The window case
                // below already refuses to emit an empty title for the same reason; this is
                // the same rule, and it was simply missing here.
                title: name(for: application, processID: application.processID),
                subtitle: owned.count == 1 ? "1 window" : "\(owned.count) windows",
                source: .application(application.processID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            )
        }
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

    private static func windows(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.windows.compactMap { window in
            guard let application = window.owningApplication, let bounds = unionFrame(of: [window]) else {
                return nil
            }

            // A window with no title is usually a panel or a splash sheet. Naming it after
            // its application is more use than an empty cell in the picker.
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? application.applicationName
            let scale = backingScale(for: bounds)

            return CaptureSourceDescriptor(
                kind: .window,
                title: title,
                subtitle: application.applicationName,
                source: .window(window.windowID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            )
        }
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

    func makeFilter(for source: CaptureSource) throws -> SCContentFilter {
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
            return SCContentFilter(display: display, excludingWindows: [])

        case .application(let pid):
            guard let application = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.sourceUnavailable("That application is no longer running.")
            }
            // An application filter is defined relative to a display, so one has to be
            // named even though the filter is by process. The display the application's
            // windows are actually on is the only sensible choice: picking the main display
            // would composite nothing for an app whose windows are all on a second screen.
            let owned = content.windows.filter { $0.owningApplication?.processID == pid }
            guard let display = Self.hostingDisplay(for: Self.unionFrame(of: owned), in: content) else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.sourceUnavailable("That window has been closed.")
            }
            // Desktop-independent, so the window keeps being captured when it is covered by
            // another window or dragged to a different display. The alternative — a display
            // filter that includes this one window — captures whatever is drawn on top of it.
            return SCContentFilter(desktopIndependentWindow: window)
        }
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
