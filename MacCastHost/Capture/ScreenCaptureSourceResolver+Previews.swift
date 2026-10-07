import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension ScreenCaptureSourceResolver {
    /// The notification arrives as the switch begins; a shot taken mid-slide is half of each desktop.
    static let spaceSwitchSettle: Duration = .milliseconds(900)

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
}
