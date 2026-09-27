import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import os

private let thumbnailLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A screenshot encoded as a JPEG that fits a byte budget.
///
/// The quality steps down rather than giving up: the budget is a rule about what may travel, and
/// a picture that misses it by a few kilobytes is still a picture of the thing it is of. Each step
/// exists so a busy screen costs a slightly softer tile instead of costing the tile entirely.
/// Only when even the last rung misses does this return `nil`, which the caller draws as an empty
/// tile.
///
/// - Parameter what: names the thing in the log, since two features drop pictures this way.
func encodeJPEG(
    _ image: CGImage,
    quality: CGFloat,
    maximumBytes: Int,
    what: String
) -> Data? {
// The last quality at which a screenshot is still recognisably itself at tile size.
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
/// A lock-guarded class rather than an actor, as with the rest of the capture layer: the shots are
/// taken on a background task and read while a catalogue is being built on its own schedule, and
/// nothing here waits long enough to be worth suspending over.
///
/// In memory only, unlike ``SpacePreviewCache``. An application that is running is on screen, so
/// its picture can be retaken for the price of one screenshot, and every launch makes the last set
/// stale anyway.
final class SourceThumbnailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [String: SourceThumbnail] = [:]

/// How wide a thumbnail is, in pixels.
///
/// `SCStreamConfiguration`'s dimensions are pixels and not points. Half a desktop preview, because
/// this is drawn in a grid tile rather than across a panel.
    static let pixelWidth = 240

    /// JPEG quality, and JPEG rather than PNG for the reason ``SourceThumbnail`` gives.
    static let jpegQuality: CGFloat = 0.45

    /// The picture for one source, or `nil` if none has been taken.
    func thumbnail(for source: CaptureSource) -> SourceThumbnail? {
        lock.withLock { shots[source.stableID] }
    }

/// Files a picture under the source it is of.
///
/// Keyed by ``CaptureSource/stableID`` rather than by position in the catalogue: the catalogue is
/// rebuilt from scratch on every launch and quit, and a position is not a name. The same
/// application would otherwise keep its picture, lose it, or inherit the one above it depending
/// only on what else was running.
    /// Returns whether the picture differs from the one already held. The encoder is
    /// deterministic, so identical pixels give identical bytes.
    @discardableResult
    func store(_ thumbnail: SourceThumbnail, for source: CaptureSource) -> Bool {
        lock.withLock {
            guard shots[source.stableID]?.jpegData != thumbnail.jpegData else { return false }
            shots[source.stableID] = thumbnail
            return true
        }
    }

/// Drops every picture whose application is no longer offered.
///
/// Called once per catalogue build with the applications that build produced. An application that
/// quit is not in it, and its picture is a photograph of a window that is no longer on screen.
    func keep(only liveIDs: Set<String>) {
        lock.withLock { shots = shots.filter { liveIDs.contains($0.key) } }
    }

/// Encodes a screenshot as the thumbnail that travels in the catalogue.
///
/// Split from the capture so that this half has no ScreenCaptureKit in it and can be handed any
/// image.
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
