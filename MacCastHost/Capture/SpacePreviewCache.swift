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
/// Deliberately not a ``SpacePreview``: that carries the 1-based number the client draws the
/// tile under, and the number is the one thing about a desktop that is not stable. It is
/// stamped on at send time, from wherever the desktop currently sits in the Space list.
struct SpaceShot: Sendable, Equatable {
    let width: Int
    let height: Int
    let jpegData: Data
}

/// Numbers one display's captured desktops the way the client will display them.
///
/// A free function on purpose. Which picture ends up under which number is the part of this
/// feature that can be wrong while still looking plausible — every tile shows *a* desktop —
/// and it is the only part that needs no window server, no display and no Screen Recording
/// permission to exercise.
///
/// Numbering always restarts at 1, because it is called once per display and that is how the
/// window server numbers Spaces and how the client labels the tiles: a Mac with two screens has
/// two desktops called "Desktop 1". Running a single count across every screen would disagree
/// with the `current` the window server reports for each.
///
/// `shots` is keyed by Space ID rather than by position — IDs are unique across displays, so one
/// cache answers every screen. `activeID` is an input only so that a read which caught the window
/// server mid-change — the list and the active Space are read one after the other, and the user
/// can switch in between — produces no previews at all instead of tiles numbered against a list
/// that no longer describes the screen.
/// The pictures for `ids`, numbered by their position in it.
///
/// **No check that the active Space is among them**, which is a change: it used to return
/// nothing at all unless the caller's list contained the active ID, as a guard against a
/// transient read where the two disagreed. That guard cannot survive a fullscreen application —
/// the active Space is then deliberately absent from the desktops the caller passes — and it
/// is not needed, because the shots are keyed by Space ID and only their *number* comes from
/// position. A list read a moment out of date yields one client refresh with the right
/// pictures under shifted numbers, rather than a display with no pictures at all.
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

    /// One display's previews, in Space order and numbered as the client numbers them.
    func previews(ids: [Int32]) -> [SpacePreview] {
        orderedSpacePreviews(ids: ids, shots: lock.withLock { shots })
    }

    /// Drops every picture whose desktop no longer exists on any display.
    ///
    /// Called once per catalogue build with the union of every display's Space IDs, rather than
    /// from ``previews(ids:activeID:)``: a display only knows its own Spaces, so pruning there
    /// would throw away the other screens' pictures. An ID is what makes the numbers safe to
    /// shift; it is also what would let a removed desktop's picture sit in memory for the life of
    /// the process.
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
    /// **Kept on disk because a desktop can only be photographed while it is on screen.** These
    /// pictures are the only record of the desktops the user is not currently looking at, so
    /// losing them on every relaunch means tiles that stay blank until every one of those
    /// desktops has been walked through again — for two screens and five desktops, a long and
    /// entirely avoidable tour. Keyed by Space ID, which the window server keeps stable across
    /// launches, so a picture comes back to the desktop it belongs to.
    init() {
        shots = PreviewStore.load()
    }

    func store(_ shot: SpaceShot, for spaceID: Int32) {
        lock.withLock { shots[spaceID] = shot }
        // Written outside the lock. This is the only call here that touches the disk, and holding
        // the lock across file I/O would block the catalogue read that is waiting on it.
        PreviewStore.write(shot, for: spaceID)
    }

    /// Photographs a display and **hands the picture back rather than filing it**.
    ///
    /// The caller files it, and that split is the whole point of the signature. A screenshot is
    /// not instantaneous: between the read that established which desktop was showing and the
    /// shutter there is room for the person to have switched again, and a picture filed under
    /// the wrong id is one the client draws as a desktop it is not — a tile labelled Desktop 2
    /// showing Desktop 3, with nothing on screen to say which of the two is lying. Only the
    /// caller knows which id the picture was meant to be of, so only the caller can check that
    /// it still is.
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

/// The previews on disk, so a relaunch does not mean starting over.
///
/// Under the caches directory rather than Application Support: these are decoration that can be
/// rebuilt by looking at a desktop, the system is free to evict them under disk pressure, and
/// losing one costs a thumbnail rather than a fact.
private enum PreviewStore {
    /// How old a picture may be and still be worth showing.
    ///
    /// A Space ID is stable but it is not reserved: delete a desktop and a later one can be given
    /// the number. A picture from months ago would then be drawn under the name of a desktop it
    /// was never a picture of — the failure the ID-keyed cache exists to avoid, arriving by
    /// another route.
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
    /// The size is needed to number a preview and is not carried in the file name. Decoding a
    /// whole desktop screenshot on every launch would be the expensive way to learn something the
    /// header already says.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
