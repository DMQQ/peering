import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import os

private let thumbnailLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Quality steps down until it fits the budget; returns nil only when the last step misses.
func encodeJPEG(
    _ image: CGImage,
    quality: CGFloat,
    maximumBytes: Int,
    what: String
) -> Data? {
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

/// In memory only: a running application picture can be retaken cheaply.
final class SourceThumbnailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [String: SourceThumbnail] = [:]

/// Pixels, not points (SCStreamConfiguration).
    static let pixelWidth = 240

    static let jpegQuality: CGFloat = 0.45

    func thumbnail(for source: CaptureSource) -> SourceThumbnail? {
        lock.withLock { shots[source.stableID] }
    }

/// Keyed by stableID, not catalogue position, which is rebuilt on every launch.
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

/// Called once per catalogue build; a quit application picture is stale.
    func keep(only liveIDs: Set<String>) {
        lock.withLock { shots = shots.filter { liveIDs.contains($0.key) } }
    }

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
