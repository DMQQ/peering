import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RemoteCore
import ScreenCaptureKit
import os

private let previewLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// One desktop, photographed.
///
/// Deliberately not a ``SpacePreview``: that carries the 1-based number the client draws the tile
/// under, and the number is the one thing about a desktop that is not stable. It is stamped on at
/// send time.
struct SpaceShot: Sendable, Equatable {
    let width: Int
    let height: Int
    let jpegData: Data
}

/// Numbers one display's captured desktops the way the client will display them.
///
/// The pictures for `ids`, numbered by their position in it. Numbering always restarts at 1,
/// because it is called once per display and that is how the window server numbers Spaces: a Mac
/// with two screens has two desktops called "Desktop 1". A single count across every screen would
/// disagree with the `current` the window server reports for each.
///
/// `shots` is keyed by Space ID rather than by position, so one cache answers every screen. There
/// is no check that the active Space is among `ids`: a fullscreen application puts the active
/// Space deliberately outside the desktops the caller passes, and since only the number comes from
/// position, a list read a moment out of date yields one client refresh with the right pictures
/// under shifted numbers rather than a display with no pictures at all.
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

/// What each desktop looked like the last time the host was on it.
///
/// A lock-guarded class rather than an actor, as with the rest of the capture layer: the shots are
/// taken on a background task and read while a catalogue is being built on its own schedule.
final class SpacePreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [Int32: SpaceShot] = [:]

/// The width of a preview, in pixels. `SCStreamConfiguration`'s dimensions are pixels and not
/// points. Twice the tile the client draws is what a Retina screen wants, and already past the
/// point where more detail would be visible.
    static let pixelWidth = 320

/// JPEG quality, and JPEG rather than PNG: 0.6 puts the artefacts below what a tile that size can
/// resolve and costs a fraction of what the lossless encoder would spend.
    static let jpegQuality: CGFloat = 0.6

/// The largest preview worth carrying.
///
/// The whole catalogue is re-sent whenever anything in it changes, so one pathological preview is
/// a cost paid by every push for as long as the host runs.
    static let maximumByteCount = 64 * 1_024

    /// One display's previews, in Space order and numbered as the client numbers them.
    func previews(ids: [Int32]) -> [SpacePreview] {
        orderedSpacePreviews(ids: ids, shots: lock.withLock { shots })
    }

/// Drops every picture whose desktop no longer exists on any display.
///
/// Called once per catalogue build with the union of every display's Space IDs: a display only
/// knows its own Spaces, so pruning there would throw away the other screens' pictures.
    func keep(only liveIDs: Set<Int32>) {
        let removed = lock.withLock { () -> [Int32] in
            let gone = shots.keys.filter { !liveIDs.contains($0) }
            shots = shots.filter { liveIDs.contains($0.key) }
            return gone
        }
        PreviewStore.remove(removed)
    }

/// Loads what previous launches photographed.
///
/// Kept on disk because a desktop can only be photographed while it is on screen: these pictures
/// are the only record of the desktops the user is not currently looking at. Keyed by Space ID,
/// which the window server keeps stable across launches.
    init() {
        shots = PreviewStore.load()
    }

    func store(_ shot: SpaceShot, for spaceID: Int32) {
        lock.withLock { shots[spaceID] = shot }
// Written outside the lock: this is the only call here that touches the disk, and holding the
// lock across file I/O would block the catalogue read waiting on it.
        PreviewStore.write(shot, for: spaceID)
    }

/// Photographs a display and hands the picture back rather than filing it.
///
/// The caller files it, and that split is the point of the signature: a screenshot is not
/// instantaneous, so between the read that established which desktop was showing and the shutter
/// there is room for the person to have switched again. A picture filed under the wrong id is one
/// the client draws as a desktop it is not, and only the caller knows which id it was meant to be
/// of.
///
/// Never throws, and never reports a failure to anyone but the log. A preview is decoration on the
/// client's picker: a host without Screen Recording, a display that went away, and a future macOS
/// that refuses the call all have to leave that Space with no preview rather than cost the client
/// its source list.
///
/// A one-shot screenshot rather than a second `SCStream`, which would compete with the live
/// session's stream for the same capture hardware to produce a picture only wanted once.
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

/// A screenshot, encoded as the JPEG that travels in a preview.
///
/// Split from the capture above so that the encoding has no ScreenCaptureKit in it. See `encodeJPEG`
/// for why the budget is stepped down rather than refused.
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

/// The previews on disk, so a relaunch does not mean starting over.
///
/// Under the caches directory rather than Application Support: these are decoration that can be
/// rebuilt by looking at a desktop, and the system is free to evict them under disk pressure.
private enum PreviewStore {
/// How old a picture may be and still be worth showing.
///
/// A Space ID is stable but it is not reserved: delete a desktop and a later one can be given the
/// number, so a picture from months ago would be drawn under the name of a desktop it was never a
/// picture of.
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

/// The pixel dimensions of a JPEG, read from its header rather than by decoding the image.
///
/// The size is needed to number a preview and is not carried in the file name.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
