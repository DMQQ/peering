import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

let resolverLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A lock-guarded class rather than an actor: the ScreenCaptureKit types carry no `Sendable` annotations, so an actor boundary buys no checked safety and forces `await` everywhere.
/// Listens for the notifications that change the catalogue and marks the snapshot stale, rather than polling.
final class ScreenCaptureSourceResolver: CaptureSourceResolver, @unchecked Sendable {
    let lock = NSLock()

    /// Kept because ``makeFilter(for:)`` is synchronous and needs the same `SCWindow`/`SCDisplay` instances the catalogue used.
    var snapshot: SCShareableContent?
    var installedApplicationsCache: [InstalledApplicationDescriptor]?
    var isStale = true

    /// Window numbers when ``snapshot`` was taken. Under ``lock``.
    var windowIDsAtSnapshot: Set<CGWindowID>?

    var openOnSomeDesktop: Set<CGWindowID> = []

    /// When an enumeration with no window in it was first seen. See ``serve(_:)``. Under ``lock``.
    var firstWindowlessReadAt: Date?

    /// Several times the length of the Space change that produces windowless readings.
    static let windowlessReadGrace: TimeInterval = 6
    var observers: [NSObjectProtocol] = []

    let spacePreviews = SpacePreviewCache()

    /// Keyed by ``CaptureSource/stableID`` so an application keeps its picture across catalogue rebuilds.
    let sourceThumbnails = SourceThumbnailCache()

    /// `activeSpaceDidChangeNotification` does not say which display changed; without this every display would be photographed on every switch. Under ``lock``.
    var lastActiveSpace: [UInt32: Int32] = [:]

    /// Window changes on a showing desktop announce nothing, so this lets ``captureActiveSpacePreview()`` re-shoot a desktop nobody has left. Under ``lock``.
    var lastPreviewAt: [UInt32: DispatchTime] = [:]

    /// The window server reports the new Space ID as soon as a switch starts, so only time since arrival tells a finished desktop from one still sliding in. Under ``lock``.
    var spaceArrivedAt: [UInt32: DispatchTime] = [:]

    /// Bumped when a Space switch starts. The Space ID moves late, so a shot taken as a switch begins shows the desktop being left; it is filed only if this has not moved ``postShutterHold`` later. Under ``lock``.
    var spaceChangeGeneration = 0

    private var spacePoll: Task<Void, Never>?

    /// A switch on a second display can pass with no notification, so the notification is only the fast path and this poll is the one that is always right.
    private static let spacePollInterval: Duration = .seconds(2)

    /// Long enough that a desktop being worked on is not photographed every couple of seconds, short enough to look current.
    static let spacePreviewMaxAgeNanoseconds: UInt64 = 12 * 1_000_000_000

    /// Fired when the catalogue is out of date; the host re-reads ``catalog()`` and pushes, since pushing from inside the notification would be an unrelated thread.
    /// The flag is whether the push must go out now: pushes coalesce to three seconds, which would leave a waiting preview as a grey outline. See ``previewLanded()``.
    let onInvalidate: (@Sendable (Bool) -> Void)?

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

    /// Sources a capture proved this Mac cannot capture, and when. Only a capture that produced no frame at all is evidence.
    /// Dated so a mark expires after ``uncapturableGrace``: marks used to stand until invalidation, so a window that failed once mid-Space switch (Terminal, Zed) vanished from the phone for the session. Emptied by ``invalidate()``. Under ``lock``.
    var uncapturable: [CaptureSource: Date] = [:]

    // MARK: - Space previews

    // MARK: - Descriptors

    /// Keyed by process, the identity `SCRunningApplication` and `SCWindow.owningApplication` hand out.
    struct ApplicationIcons {
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

    // MARK: - Windows on other desktops

    // MARK: - Filters

    // MARK: - Input mapping

    // MARK: - Screen geometry

}
