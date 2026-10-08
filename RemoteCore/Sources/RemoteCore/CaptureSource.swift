import CoreGraphics
import Foundation

/// What the host is capturing. Stores platform-neutral raw values rather than `CGDirectDisplayID` or
/// `CGWindowID`, which live in macOS-only headers this module, compiled for iOS too, cannot name.
public enum CaptureSource: Codable, Sendable, Hashable {
    /// A whole display. `UInt32` is a `CGDirectDisplayID` raw value.
    case display(UInt32)
    /// Every window belonging to one process, composited. `Int32` is a `pid_t`.
    case application(Int32)
    /// A single window. `UInt32` is a `CGWindowID` raw value.
    case window(UInt32)

    /// Several sources drawn into one picture, at the rectangles the client asked for. It takes no input, since a tile's picture means a different coordinate per tile.
    case mosaic(MosaicLayout)

    public var stableID: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .application(let pid): return "application:\(pid)"
        case .window(let id): return "window:\(id)"
        case .mosaic(let layout):
            // The canvas size is part of the name but the frame rate is not: the same arrangement redrawn faster is the same picture.
            let name = "\(layout.canvas.width)x\(layout.canvas.height)"
                + layout.tiles.map { "|\($0.stableID)" }.joined()

            // Hashed by hand rather than with `Hasher`, which is seeded per process: a name that
            // changed on every launch would make the same arrangement a new picture every time.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in name.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return "mosaic:\(String(hash, radix: 16))"
        }
    }

    /// A mosaic is only asked for, never offered by the Mac, so the host refuses input while one is up.
    public var isMosaic: Bool {
        if case .mosaic = self { return true }
        return false
    }

    public var mosaicLayout: MosaicLayout? {
        if case .mosaic(let layout) = self { return layout }
        return nil
    }

    /// Whether the captured content moves unannounced; only the per-frame content rect sees an app or window being dragged or resized.
    public var contentMovesOnItsOwn: Bool {
        switch self {
        case .display: return false
        case .application, .window: return true
        // A mosaic is a display: a tile resizing must not reset where the user was looking.
        case .mosaic: return false
        }
    }
}

/// A rectangle in the canvas's own space: (0,0) at the top left of the canvas and (1,1) at its
/// bottom right, whatever the canvas's aspect ratio.
public struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Clamped copy, so a layout can describe nothing outside the canvas it is drawn in: the size is
    /// clamped first and the origin against what is left, rather than each of the four against 0…1,
    /// which would let `x: 0.9, width: 0.5` run to 1.4 and be drawn past the edge.
    public var clamped: NormalizedRect {
        let width = min(max(self.width, 0), 1)
        let height = min(max(self.height, 0), 1)
        return NormalizedRect(
            x: min(max(x, 0), 1 - width),
            y: min(max(y, 0), 1 - height),
            width: width,
            height: height
        )
    }

    public func pixels(in size: CGSize) -> CGRect {
        let rect = clamped
        return CGRect(
            x: rect.x * size.width,
            y: rect.y * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    /// Whether a normalized point lands inside this rect, half-open on the far edges, so the point
    /// where two tiles meet belongs to exactly one.
    public func contains(_ point: NormalizedPoint) -> Bool {
        let rect = clamped
        return point.x >= rect.x && point.x < rect.x + rect.width
            && point.y >= rect.y && point.y < rect.y + rect.height
    }
}

/// What a mosaic is: canvas, tiles and redraw rate. The canvas is part of its identity, see ``CaptureSource/stableID``.
public struct MosaicLayout: Codable, Sendable, Equatable, Hashable {
    /// The most tiles one mosaic may have. Nine, so a tile at the canvas cap is still 853×480 and legible. The host trims rather than refuses.
    public static let maximumTileCount = 9

    /// The most pixels a canvas may be built at, in total: the tile count alone bounds nothing, and
    /// one tile over a 7680×4320 canvas is a quarter of a billion pixels per second to composite.
    public static let maximumCanvasPixels = 2560 * 1440

    /// The area budget alone lets a 1e13 by 1 canvas through (the short side is floored at 2 afterwards), and the encoder traps converting such a width.
    public static let maximumCanvasSide: CGFloat = 8192

    public let canvas: CGSize
    public let tiles: [MosaicTile]
    public let frameRate: Int

    /// A mosaic's frame rate is its cost, multiplied. The floor is what still reads as motion; the
    /// ceiling is what a laptop should be asked for.
    public static let minimumFrameRate = 5
    public static let maximumFrameRate = 30

    public init(canvas: CGSize, tiles: [MosaicTile], frameRate: Int) {
        self.canvas = canvas
        self.tiles = tiles
        self.frameRate = frameRate
    }

    private static func sanitisedSide(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return min(max(2, value.rounded(.down)), maximumCanvasSide)
    }

    /// What a host will actually build, or `nil` when there is no mosaic. Trimmed rather than refused, since the layout comes from an untrusted device; the canvas is clamped by area, so 4000×300 fits the budget unreshaped.
    public var validated: MosaicLayout? {
        guard !tiles.isEmpty else { return nil }

        let width = Self.sanitisedSide(canvas.width)
        let height = Self.sanitisedSide(canvas.height)
        let pixels = width * height
        let budget = CGFloat(Self.maximumCanvasPixels)
        let scale = pixels > budget ? (budget / pixels).squareRoot() : 1
        // Even, because the encoder rounds down to even and the client's tile rects were measured
        // against what it asked for: an odd canvas is a picture a pixel narrower than the tiles.
        func even(_ value: CGFloat) -> CGFloat {
            max(2, ((value * scale).rounded(.down) / 2).rounded(.down) * 2)
        }

        return MosaicLayout(
            canvas: CGSize(width: even(width), height: even(height)),
            tiles: Array(tiles.prefix(Self.maximumTileCount)).map {
                MosaicTile(source: $0.source, rect: $0.rect.clamped)
            },
            frameRate: min(max(frameRate, Self.minimumFrameRate), Self.maximumFrameRate)
        )
    }
}

public struct MosaicTile: Codable, Sendable, Equatable, Hashable {
    public let source: CaptureSource
    public let rect: NormalizedRect

    public init(source: CaptureSource, rect: NormalizedRect) {
        self.source = source
        self.rect = rect
    }

    /// This tile's name: source and rect, rounded to a thousandth since floating-point round trips are not bit-exact.
    var stableID: String {
        func thousandths(_ value: Double) -> Int { Int((value * 1000).rounded()) }
        let rect = rect.clamped
        return "\(source.stableID)@\(thousandths(rect.x)),\(thousandths(rect.y)),"
            + "\(thousandths(rect.width)),\(thousandths(rect.height))"
    }
}

/// A picture of one source, for the picker's grid.
public struct SourceThumbnail: Codable, Sendable, Equatable, Hashable {
    /// The largest thumbnail worth carrying: the catalogue is re-sent on every change, so one huge one is a cost on every push.
    public static let maximumByteCount = 32 * 1_024

    /// Pixels, not points, and the pair the tile uses to keep its shape before the image is
    /// decoded: a grid that sized its rows from the pictures would reflow as they arrived.
    public let width: Int
    public let height: Int
    public let jpegData: Data

    public init(width: Int, height: Int, jpegData: Data) {
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }

    /// Refuses an oversize picture rather than truncating it. The caller reads this with `try?`, so
    /// one bad picture costs one tile instead of the catalogue. See
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        jpegData = try values.decode(Data.self, forKey: .jpegData)
        guard jpegData.count <= Self.maximumByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .jpegData,
                in: values,
                debugDescription: "Source thumbnail exceeds the protocol limit."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, jpegData
    }
}

/// One entry in the list of things the host can capture, as pushed to the client.
public struct CaptureSourceDescriptor: Codable, Sendable, Identifiable, Hashable {
    /// Icons are host-rendered PNGs, a hard ceiling since the whole catalogue is one control message.
    public static let maximumIconByteCount = 48 * 1_024

    public enum Kind: String, Codable, Sendable {
        case display, application, window
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let bundleIdentifier: String?
    public let iconPNGData: Data?
    /// A photograph of this source's content, set only for applications and only when the host was asked, so absent is the ordinary state.
    public let thumbnail: SourceThumbnail?
    public let source: CaptureSource
    /// Real pixel dimensions of the captured content, not points: `SCDisplay.width`/`height` report
    /// points, so a 5K panel reports half its actual width. This feeds the normalized→pixel mapping,
    /// and getting it wrong drifts the remote cursor on Retina displays.
    public let pixelSize: CGSize
    /// Whether this display was made by the host process, and so removable by a client via ``RemoteCommand/removeVirtualDisplay(displayID:)``. Defaults `false`, including on decode, so an older host's rows offer no remove control.
    public let isManagedVirtualDisplay: Bool
    /// Whether this display exists only in software, including the host's own switch-made one. Unlike ``isManagedVirtualDisplay``, which is true only for displays this phone may remove.
    public let isVirtualDisplay: Bool

    public init(
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        bundleIdentifier: String? = nil,
        iconPNGData: Data? = nil,
        thumbnail: SourceThumbnail? = nil,
        source: CaptureSource,
        pixelSize: CGSize,
        isManagedVirtualDisplay: Bool = false,
        isVirtualDisplay: Bool = false
    ) {
        self.id = source.stableID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.bundleIdentifier = bundleIdentifier
        self.iconPNGData = Self.boundedIcon(iconPNGData)
        self.thumbnail = thumbnail
        self.source = source
        self.pixelSize = pixelSize
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
        self.isVirtualDisplay = isVirtualDisplay || isManagedVirtualDisplay
    }

    /// This descriptor with a thumbnail attached, or itself when none. A modifier because pictures are taken later, off the capture path.
    public func withThumbnail(_ thumbnail: SourceThumbnail?) -> CaptureSourceDescriptor {
        guard let thumbnail else { return self }
        return CaptureSourceDescriptor(
            kind: kind,
            title: title,
            subtitle: subtitle,
            bundleIdentifier: bundleIdentifier,
            iconPNGData: iconPNGData,
            thumbnail: thumbnail,
            source: source,
            pixelSize: pixelSize,
            isManagedVirtualDisplay: isManagedVirtualDisplay,
            isVirtualDisplay: isVirtualDisplay
        )
    }

    private static func boundedIcon(_ data: Data?) -> Data? {
        guard let data, data.count <= maximumIconByteCount else { return nil }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, bundleIdentifier, iconPNGData, thumbnail, source, pixelSize,
             isManagedVirtualDisplay, isVirtualDisplay
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(CaptureSource.self, forKey: .source)
        id = source.stableID
        kind = try values.decode(Kind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        pixelSize = try values.decode(CGSize.self, forKey: .pixelSize)
        isManagedVirtualDisplay = try values.decodeIfPresent(Bool.self, forKey: .isManagedVirtualDisplay) ?? false
        isVirtualDisplay = (try values.decodeIfPresent(Bool.self, forKey: .isVirtualDisplay) ?? false)
            || isManagedVirtualDisplay

        // Lenient, unlike the icon below: one oversize picture drops one tile, where a throw would
        // cost the client its whole source list. See ``SourceThumbnail/init(from:)``.
        thumbnail = (try? values.decodeIfPresent(SourceThumbnail.self, forKey: .thumbnail)) ?? nil

        let icon = try values.decodeIfPresent(Data.self, forKey: .iconPNGData)
        guard icon == nil || icon!.count <= Self.maximumIconByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .iconPNGData,
                in: values,
                debugDescription: "Application icon exceeds the protocol limit."
            )
        }
        iconPNGData = icon
    }
}

/// An installed GUI application that is not currently a capturable process. It deliberately has no
/// `CaptureSource`: a PID only exists after launch, so the client asks the host to launch this
/// bundle identifier and the live catalogue supplies the real PID.
public struct InstalledApplicationDescriptor: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let bundleIdentifier: String
    public let title: String
    public let iconPNGData: Data?

    public init(bundleIdentifier: String, title: String, iconPNGData: Data? = nil) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        if let iconPNGData, iconPNGData.count <= CaptureSourceDescriptor.maximumIconByteCount {
            self.iconPNGData = iconPNGData
        } else {
            self.iconPNGData = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, title, iconPNGData
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        id = bundleIdentifier
        title = try values.decode(String.self, forKey: .title)
        let icon = try values.decodeIfPresent(Data.self, forKey: .iconPNGData)
        guard icon == nil || icon!.count <= CaptureSourceDescriptor.maximumIconByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .iconPNGData,
                in: values,
                debugDescription: "Application icon exceeds the protocol limit."
            )
        }
        iconPNGData = icon
    }
}

/// One display's desktops and which is on screen. Identified by (display, position in its ordered list).
public struct SpaceDisplay: Codable, Sendable, Equatable, Identifiable {
    public let displayID: UInt32

    /// How many Spaces this display has. Sent rather than counted from ``previews``, which is
    /// sparse: a desktop never visited since the host started still has to be offered.
    public let count: Int

    /// 1-based index of this display's active desktop, in this display's own numbering, or `nil`
    /// when the display is showing a fullscreen application, where no desktop is current.
    public let current: Int?

    /// Sparse: a Space with no entry has never been visited since the host started, or could not be captured.
    public let previews: [SpacePreview]

    public var id: UInt32 { displayID }

    public init(displayID: UInt32, count: Int, current: Int?, previews: [SpacePreview] = []) {
        self.displayID = displayID
        self.count = count
        self.current = current
        self.previews = previews
    }

    public func preview(for index: Int) -> SpacePreview? {
        previews.first { $0.index == index }
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, count, current, previews
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        count = try container.decode(Int.self, forKey: .count)
        // Absent means a fullscreen application is on screen, which is a fact rather than a missing
        // field, hence `IfPresent` and no fallback.
        current = try container.decodeIfPresent(Int.self, forKey: .current)
        previews = try container.decodeIfPresent([SpacePreview].self, forKey: .previews) ?? []
    }
}

/// Every display's desktops, as reported by the private CGS API. Populated on a best-effort basis: a
/// host that cannot read the Space lists sends `nil`, and clients fall back to the ← / → arrows
/// without a visual indicator.
public struct SpaceInfo: Codable, Sendable, Equatable {
    /// One entry per display, main display first. The ordering is load-bearing: every property below
    /// that predates this type described the main display, and reading the first entry keeps them so.
    public let displays: [SpaceDisplay]

    public init(displays: [SpaceDisplay]) {
        self.displays = displays
    }

    public var count: Int { displays.first?.count ?? 0 }
    public var current: Int? { displays.first?.current }
    public var previews: [SpacePreview] { displays.flatMap(\.previews) }
    public var totalCount: Int { displays.reduce(0) { $0 + $1.count } }

    /// Only the stored property, so `encode(to:)` can still be synthesised: the properties above are
    /// computed.
    private enum CodingKeys: String, CodingKey {
        case displays
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case count, current, previews
    }

    /// Lenient in both directions: a payload from a host built before this type described more than
    /// one display carries a flat `count`/`current`/`previews` and no `displays` key, and a
    /// synthesised decoder would throw on the missing key, taking the whole catalogue with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let displays = try container.decodeIfPresent([SpaceDisplay].self, forKey: .displays) {
            self.displays = displays
            return
        }

        // The old shape, synthesised into one display. `displayID` is 0 because that payload never
        // carried one, so there is no display to name and a fallback label is better than refusing
        // the catalogue.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.displays = [
            SpaceDisplay(
                displayID: 0,
                count: try legacy.decode(Int.self, forKey: .count),
                // Decoded as present: the old shape predates fullscreen Spaces, so it always had one.
                current: try legacy.decodeIfPresent(Int.self, forKey: .current),
                previews: try legacy.decodeIfPresent([SpacePreview].self, forKey: .previews) ?? []
            )
        ]
    }
}

/// One desktop, as the host last saw it: a snapshot, since ScreenCaptureKit only captures what is on the display.
public struct SpacePreview: Codable, Sendable, Equatable, Identifiable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let jpegData: Data

    public var id: Int { index }

    public init(index: Int, width: Int, height: Int, jpegData: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

/// The full set of capture sources the host offers, pushed atomically so a client never sees entries it cannot select.
public struct CaptureCatalog: Codable, Sendable, Equatable {
    /// Bounded because every entry carries an icon of up to ``maximumIconByteCount``; applied with `prefix`, so an overflow drops by alphabet.
    public static let maximumInstalledApplicationCount = 250
    public let displays: [CaptureSourceDescriptor]
    public let applications: [CaptureSourceDescriptor]
    public let windows: [CaptureSourceDescriptor]
    public let installedApplications: [InstalledApplicationDescriptor]
    public let spaceInfo: SpaceInfo?

    public init(
        displays: [CaptureSourceDescriptor] = [],
        applications: [CaptureSourceDescriptor] = [],
        windows: [CaptureSourceDescriptor] = [],
        installedApplications: [InstalledApplicationDescriptor] = [],
        spaceInfo: SpaceInfo? = nil
    ) {
        self.displays = displays
        self.applications = applications
        self.windows = windows
        self.installedApplications = Array(installedApplications.prefix(Self.maximumInstalledApplicationCount))
        self.spaceInfo = spaceInfo
    }

    public var all: [CaptureSourceDescriptor] { displays + applications + windows }

    public func descriptor(for source: CaptureSource) -> CaptureSourceDescriptor? {
        all.first { $0.source == source }
    }

    /// A defensive view for clients receiving a catalogue from an older or custom host which may put
    /// a running bundle in both sections.
    public var installedApplicationsNotRunning: [InstalledApplicationDescriptor] {
        let runningBundleIDs = Set(applications.compactMap(\.bundleIdentifier))
        return installedApplications.filter { !runningBundleIDs.contains($0.bundleIdentifier) }
    }

    private enum CodingKeys: String, CodingKey {
        case displays, applications, windows, installedApplications, spaceInfo
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displays = try values.decodeIfPresent([CaptureSourceDescriptor].self, forKey: .displays) ?? []
        applications = try values.decodeIfPresent([CaptureSourceDescriptor].self, forKey: .applications) ?? []
        windows = try values.decodeIfPresent([CaptureSourceDescriptor].self, forKey: .windows) ?? []
        installedApplications = Array((try values.decodeIfPresent(
            [InstalledApplicationDescriptor].self,
            forKey: .installedApplications
        ) ?? []).prefix(Self.maximumInstalledApplicationCount))
        spaceInfo = try values.decodeIfPresent(SpaceInfo.self, forKey: .spaceInfo)
    }
}
