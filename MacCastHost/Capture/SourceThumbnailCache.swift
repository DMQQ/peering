import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import os

private let thumbnailLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A screenshot encoded as a JPEG that fits a byte budget.
///
/// Lifted out of ``SpacePreviewCache/shot(from:)`` the day the source thumbnails became a second
/// caller. The two differ in quality and in how many bytes they will spend, and not at all in how
/// a `CGImage` becomes a JPEG — which was, until then, two copies of the same six lines waiting
/// to drift apart.
///
/// **Steps the quality down rather than giving up.** The budget is a rule about what may travel,
/// and a picture that misses it by a few kilobytes is still a picture of the thing it is of. The
/// first encode is the one whose quality was chosen; each step past it exists so that a busy
/// screen costs a slightly softer tile instead of costing the tile entirely. Only when even the
/// last rung misses does this return `nil`, which the caller draws as an empty tile.
///
/// - Parameter what: names the thing in the log, since two features now drop pictures this way
///   and "dropped at N bytes" with no subject would not say which.
func encodeJPEG(
    _ image: CGImage,
    quality: CGFloat,
    maximumBytes: Int,
    what: String
) -> Data? {
    // A floor, because the ladder has to end somewhere and this is the last quality at which a
    // screenshot is still recognisably itself at tile size.
    let floor: CGFloat = 0.3

    var attempt = quality
    while true {
        let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: attempt]
        )
        guard let data else { return nil }

        if data.count <= maximumBytes {
            if attempt < quality {
                thumbnailLog.notice("""
                    \(what, privacy: .public) softened to \
                    \(attempt, privacy: .public) to fit \(maximumBytes, privacy: .public) bytes
                    """)
            }
            return data
        }
        guard attempt > floor else {
            thumbnailLog.notice("""
                \(what, privacy: .public) dropped at \(data.count, privacy: .public) bytes, \
                over the \(maximumBytes, privacy: .public) byte budget even at the floor
                """)
            return nil
        }
        attempt = max(floor, attempt - 0.15)
    }
}

/// What each application looked like when a client last asked to see it.
///
/// **A lock-guarded class, not an actor**, for the same reason as the rest of the capture layer:
/// the shots are taken on a background task and read while a catalogue is being built on its own
/// schedule, and nothing in here ever waits long enough to be worth suspending over.
///
/// **In memory only, which is the difference between this and ``SpacePreviewCache``.** A desktop's
/// picture is the only record of a desktop the user is not looking at, so losing it means tiles
/// that stay blank until it has been walked through again — hence that cache writes to disk. An
/// application that is running *is* on screen, so a picture of it can be retaken at any moment for
/// the price of one screenshot, and every launch makes the last set stale anyway. Writing these
/// to disk would be paying to preserve something already worthless.
final class SourceThumbnailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [String: SourceThumbnail] = [:]

    /// How wide a thumbnail is, in **pixels**.
    ///
    /// `SCStreamConfiguration`'s dimensions are pixels and not points, the same distinction the
    /// catalogue's display geometry already documents. Half a desktop preview, because this is
    /// drawn in a grid tile rather than across a panel and a phone shows several at once.
    static let pixelWidth = 320

    /// JPEG quality, and JPEG rather than PNG for the reason ``SourceThumbnail`` gives.
    static let jpegQuality: CGFloat = 0.6

    /// The picture for one source, or `nil` if none has been taken.
    func thumbnail(for source: CaptureSource) -> SourceThumbnail? {
        lock.withLock { shots[source.stableID] }
    }

    /// Files a picture under the source it is of.
    ///
    /// Keyed by ``CaptureSource/stableID`` rather than by position in the catalogue, because the
    /// catalogue is rebuilt from scratch on every launch and quit and a position is not a name:
    /// the same application would keep its picture, lose it, or inherit the one above it
    /// depending only on what else was running.
    func store(_ thumbnail: SourceThumbnail, for source: CaptureSource) {
        lock.withLock { shots[source.stableID] = thumbnail }
    }

    /// Drops every picture whose application is no longer offered.
    ///
    /// Called once per catalogue build with the applications that build actually produced, which
    /// is the set the client is about to be shown. An application that quit, or whose last window
    /// closed, is not in it — and its picture is a photograph of a window that is no longer on
    /// screen, which is the one thing a thumbnail must never be.
    func keep(only liveIDs: Set<String>) {
        lock.withLock { shots = shots.filter { liveIDs.contains($0.key) } }
    }

    /// Encodes a screenshot as the thumbnail that travels in the catalogue.
    ///
    /// Split from the capture for the same reason ``SpacePreviewCache/shot(from:)`` is: this half
    /// has no ScreenCaptureKit in it and can be handed any image.
    static func thumbnail(from image: CGImage) -> SourceThumbnail? {
        guard let data = encodeJPEG(
            image,
            quality: jpegQuality,
            maximumBytes: SourceThumbnail.maximumByteCount,
            what: "source thumbnail"
        ) else { return nil }
        return SourceThumbnail(width: image.width, height: image.height, jpegData: data)
    }
}
