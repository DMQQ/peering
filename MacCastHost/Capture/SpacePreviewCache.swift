import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let previewLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// One desktop, photographed.
///
/// Deliberately not a ``SpacePreview``: that carries the 1-based number the client draws the
/// tile under, and the number is the one thing about a desktop that is not stable. It is
/// stamped on at send time, from wherever the desktop currently sits in the Space list.
struct SpaceShot: Sendable, Equatable {
    let width: Int
    let height: Int
    let jpegData: Data
}

/// Numbers a set of captured desktops the way the client will display them.
///
/// A free function on purpose. Which picture ends up under which number is the part of this
/// feature that can be wrong while still looking plausible — every tile shows *a* desktop —
/// and it is the only part that needs no window server, no display and no Screen Recording
/// permission to exercise.
///
/// `shots` is keyed by Space ID rather than by position. `activeID` is an input only so that a
/// read which caught the window server mid-change — the list and the active Space are read one
/// after the other, and the user can switch in between — produces no previews at all instead
/// of tiles numbered against a list that no longer describes the screen.
func orderedSpacePreviews(
    ids: [Int32],
    activeID: Int32,
    shots: [Int32: SpaceShot]
) -> [SpacePreview] {
    guard ids.contains(activeID) else { return [] }

    return ids.enumerated().compactMap { offset, id in
        guard let shot = shots[id] else { return nil }
        return SpacePreview(
            index: offset + 1,
            width: shot.width,
            height: shot.height,
            jpegData: shot.jpegData
        )
    }
}

/// What each desktop looked like the last time the host was on it.
///
/// **A lock-guarded class, not an actor**, for the same reason as the rest of the capture
/// layer: the shots are taken on a background task and read while a catalogue is being built
/// on its own schedule, and nothing in here ever waits long enough to be worth suspending over.
final class SpacePreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [Int32: SpaceShot] = [:]

    /// The width of a preview, in **pixels**. `SCStreamConfiguration`'s dimensions are pixels
    /// and not points, the same distinction the catalogue's display geometry already documents.
    /// Twice the tile the client draws is what a Retina screen wants, and it is already past
    /// the point where more detail would be visible in it.
    static let pixelWidth = 320

    /// JPEG quality, and JPEG rather than PNG: this is a photograph of a screen shown as a
    /// thumbnail, where 0.6 puts the artefacts below what a tile that size can resolve and
    /// costs a fraction of what the lossless encoder would spend saying the same thing.
    static let jpegQuality: CGFloat = 0.6

    /// The largest preview worth carrying.
    ///
    /// The whole catalogue is re-sent whenever anything in it changes — every application
    /// launch, every Space switch — so one pathological preview is a cost paid by every push
    /// for as long as the host runs. A desktop is smooth enough that this is far above what
    /// the size and quality above produce; reaching it means something has gone wrong with the
    /// image rather than that the desktop is busy.
    static let maximumByteCount = 64 * 1_024

    /// The previews to send, in Space order and numbered as the client numbers them.
    ///
    /// Pruning happens here, because this is the only place that knows which Spaces still
    /// exist. An ID is what makes the numbers safe to shift; it is also what would let a
    /// removed desktop's picture sit in memory for the life of the process.
    func previews(ids: [Int32], activeID: Int32) -> [SpacePreview] {
        let current = lock.withLock { () -> [Int32: SpaceShot] in
            shots = shots.filter { ids.contains($0.key) }
            return shots
        }
        return orderedSpacePreviews(ids: ids, activeID: activeID, shots: current)
    }

    func store(_ shot: SpaceShot, for spaceID: Int32) {
        lock.withLock { shots[spaceID] = shot }
    }

    /// Whether a Space has a picture, which is how a capture that produced one is told apart
    /// from a capture that failed. The difference is a pushed catalogue, and there is no point
    /// pushing one for a thumbnail that is not there.
    func hasShot(for spaceID: Int32) -> Bool {
        lock.withLock { shots[spaceID] != nil }
    }

    /// Photographs a display and files the result against a Space.
    ///
    /// **Never throws, and never reports a failure to anyone but the log.** A preview is
    /// decoration on the client's picker: a host without Screen Recording permission, a display
    /// that went away between the filter being built and the shutter, and a future macOS that
    /// refuses the call all have to leave that Space with no preview — the client draws an
    /// empty tile, which is the truth — rather than cost the client its source list or its
    /// session over a thumbnail.
    ///
    /// A one-shot screenshot rather than a second `SCStream`: the host runs one stream already
    /// for the live session, and a stream per desktop would compete with it for the same
    /// capture hardware to produce a picture that is only wanted once.
    func capture(spaceID: Int32, filter: SCContentFilter, configuration: SCStreamConfiguration) async {
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let shot = Self.shot(from: image) else {
                previewLog.notice("space preview \(spaceID, privacy: .public) could not be encoded")
                return
            }
            store(shot, for: spaceID)
        } catch {
            previewLog.notice("""
                space preview \(spaceID, privacy: .public) not captured: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// A screenshot, encoded as the JPEG that travels in a preview.
    ///
    /// Split from the capture above so that the encoding has no ScreenCaptureKit in it: this
    /// half can be handed any image.
    static func shot(from image: CGImage) -> SpaceShot? {
        let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        )
        guard let data else { return nil }
        guard data.count <= maximumByteCount else {
            previewLog.notice("""
                space preview dropped at \(data.count, privacy: .public) bytes, \
                over the \(maximumByteCount, privacy: .public) byte budget
                """)
            return nil
        }
        return SpaceShot(width: image.width, height: image.height, jpegData: data)
    }
}
