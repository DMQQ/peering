import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RemoteCore
import ScreenCaptureKit
import os

private let previewLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Not a SpacePreview: the 1-based number is unstable, so it is stamped on at send time.
struct SpaceShot: Sendable, Equatable {
    let width: Int
    let height: Int
    let jpegData: Data
}

/// Numbering restarts at 1 per display, as the window server numbers Spaces.
/// No check that the active Space is among ids: a fullscreen application puts it outside the desktops passed.
func orderedSpacePreviews(
    ids: [Int32],
    shots: [Int32: SpaceShot]
) -> [SpacePreview] {
    ids.enumerated().compactMap { offset, id in
        guard let shot = shots[id] else { return nil }
        return SpacePreview(
            index: offset + 1,
            width: shot.width,
            height: shot.height,
            jpegData: shot.jpegData
        )
    }
}

final class SpacePreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [Int32: SpaceShot] = [:]

    static let pixelWidth = 320

    static let jpegQuality: CGFloat = 0.6

/// The whole catalogue is re-sent on any change, so one oversized preview costs every push.
    static let maximumByteCount = 64 * 1_024

    func previews(ids: [Int32]) -> [SpacePreview] {
        orderedSpacePreviews(ids: ids, shots: lock.withLock { shots })
    }

/// Called with the union of every display Space IDs: pruning per display would drop the other screens pictures.
    func keep(only liveIDs: Set<Int32>) {
        let removed = lock.withLock { () -> [Int32] in
            let gone = shots.keys.filter { !liveIDs.contains($0) }
            shots = shots.filter { liveIDs.contains($0.key) }
            return gone
        }
        PreviewStore.remove(removed)
    }

/// On disk because a desktop can only be photographed while on screen. Keyed by Space ID, stable across launches.
    init() {
        shots = PreviewStore.load()
    }

    @discardableResult
    func store(_ shot: SpaceShot, for spaceID: Int32) -> Bool {
        let changed = lock.withLock { () -> Bool in
            guard shots[spaceID] != shot else { return false }
            shots[spaceID] = shot
            return true
        }
        guard changed else { return false }
// Outside the lock: file I/O under it would block catalogue reads.
        PreviewStore.write(shot, for: spaceID)
        return true
    }

/// The caller files it: a screenshot is not instantaneous, so the desktop may have changed and only the caller knows which id was meant.
/// Never throws; failures only reach the log, since a preview must not cost the client its source list.
/// A one-shot screenshot rather than a second SCStream, which would compete with the live one.
    func capture(
        spaceID: Int32, filter: SCContentFilter, configuration: SCStreamConfiguration
    ) async -> SpaceShot? {
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let shot = Self.shot(from: image) else {
                previewLog.notice("space preview \(spaceID, privacy: .public) could not be encoded")
                return nil
            }
            return shot
        } catch {
            previewLog.notice("""
                space preview \(spaceID, privacy: .public) not captured: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    static func shot(from image: CGImage) -> SpaceShot? {
        guard let data = encodeJPEG(
            image,
            quality: jpegQuality,
            maximumBytes: maximumByteCount,
            what: "space preview"
        ) else { return nil }
        return SpaceShot(width: image.width, height: image.height, jpegData: data)
    }
}

/// In the caches directory, not Application Support: rebuildable, and the system may evict it.
private enum PreviewStore {
/// Space IDs are reused after a desktop is deleted, so an old picture could be drawn under the wrong desktop.
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = caches.appendingPathComponent("SpacePreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func file(for spaceID: Int32) -> URL? {
        directory?.appendingPathComponent("\(spaceID).jpg")
    }

    static func load() -> [Int32: SpaceShot] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [:] }

        let oldest = Date().addingTimeInterval(-maximumAge)
        var shots: [Int32: SpaceShot] = [:]
        for name in names where name.hasSuffix(".jpg") {
            let url = directory.appendingPathComponent(name)
            guard let id = Int32(name.dropLast(4)),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  modified > oldest,
                  let data = try? Data(contentsOf: url),
                  let size = pixelSize(of: data)
            else { continue }
            shots[id] = SpaceShot(width: size.width, height: size.height, jpegData: data)
        }
        return shots
    }

    static func write(_ shot: SpaceShot, for spaceID: Int32) {
        guard let file = file(for: spaceID) else { return }
        try? shot.jpegData.write(to: file, options: .atomic)
    }

    static func remove(_ spaceIDs: [Int32]) {
        for id in spaceIDs {
            guard let file = file(for: id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
