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

    /// Several sources drawn into one picture, at the rectangles the client asked for.
    ///
    /// The only source here that is not a source: everything else names something macOS is already
    /// showing, while this one names a canvas the host builds out of several, because the phone has
    /// one video layer and cannot be sent N streams. The Mac opens one capture per distinct tile,
    /// draws each into its rectangle, and encodes the result once.
    ///
    /// It takes no input, since a tile's picture means a different coordinate per tile. Selecting a
    /// tile gives a source back its input, as an ordinary source switch. See ``MosaicTile``.
    case mosaic(MosaicLayout)

    /// Stable string used as the `Identifiable` id and in persisted selections,
    /// so a client's chosen source survives a reconnect.
    public var stableID: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .application(let pid): return "application:\(pid)"
        case .window(let id): return "window:\(id)"
        case .mosaic(let layout):
            // The canvas as well as the tiles: two arrangements of the same tiles at different
            // canvas sizes are two pictures. The frame rate is deliberately not here: redrawing an
            // arrangement faster is the same arrangement.
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

    /// Whether this source is a canvas the host builds rather than something the Mac is showing. A
    /// mosaic is never offered by the Mac, only asked for, so the host refuses input while one is up
    /// and the picker has no row to tick for it.
    public var isMosaic: Bool {
        if case .mosaic = self { return true }
        return false
    }

    /// The layout of a mosaic source, or `nil` for anything else.
    public var mosaicLayout: MosaicLayout? {
        if case .mosaic(let layout) = self { return layout }
        return nil
    }

    /// Whether the captured content moves without anything announcing it.
    ///
    /// A display's geometry read once at capture starts stays true; only the per-frame content rect
    /// observes an application or a window being dragged and resized.
    public var contentMovesOnItsOwn: Bool {
        switch self {
        case .display: return false
        case .application, .window: return true
        // A mosaic is a display, not a window: its canvas is a size the client asked for and keeps,
        // while the tiles inside it come and go without it changing shape. A tile resizing is not a
        // reason to throw away where the user was looking; a different arrangement is.
        case .mosaic: return false
        }
    }
}

/// A rectangle in the canvas's own space: (0,0) at the top left of the canvas and (1,1) at its
/// bottom right, whatever the canvas's aspect ratio.
///
/// Normalized rather than in pixels, for the same reason ``NormalizedPoint`` is: neither end can name
/// the other's units. The host multiplies by the canvas's pixels, the client by the picture's rect.
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

    /// The rect in a canvas of the given pixel size, for the host's compositor.
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

/// What a mosaic is: the canvas it is drawn in, what sits on it, and how often it is redrawn. One
/// value rather than three parameters, because the canvas is part of what a mosaic is and
/// ``CaptureSource/stableID`` has to tell two canvases apart.
public struct MosaicLayout: Codable, Sendable, Equatable, Hashable {
    /// The most tiles one mosaic may have, and the number both ends read.
    ///
    /// Nine, because a grid is square and nine of the 2560×1440 canvas cap, see
    /// ``maximumCanvasPixels``, are 853×480 a tile, where a window's title is still legible.
    ///
    /// A limit on the Mac rather than the phone, where every tile is a capture of its own; the host
    /// trims rather than refuses, so a newer client gets a smaller mosaic rather than no picture.
    public static let maximumTileCount = 9

    /// The most pixels a canvas may be built at, in total: the tile count alone bounds nothing, and
    /// one tile over a 7680×4320 canvas is a quarter of a billion pixels per second to composite.
    public static let maximumCanvasPixels = 2560 * 1440

    /// The canvas in pixels, as the client wants it drawn on its own screen.
    public let canvas: CGSize
    public let tiles: [MosaicTile]
    /// How often the canvas is redrawn, which is every tile's frame rate as well as the
    /// encoder's. See ``minimumFrameRate``.
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

    /// What a host will actually build, or `nil` when there is no mosaic in this at all.
    ///
    /// Trimmed rather than refused, since the layout arrives from a device the Mac does not control.
    /// The canvas is clamped by area rather than by each side, so a 4000×300 canvas is trimmed to fit
    /// the budget rather than reshaped.
    public var validated: MosaicLayout? {
        guard !tiles.isEmpty else { return nil }

        let width = max(2, canvas.width.rounded(.down))
        let height = max(2, canvas.height.rounded(.down))
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

/// One source's place in a mosaic.
public struct MosaicTile: Codable, Sendable, Equatable, Hashable {
    public let source: CaptureSource
    public let rect: NormalizedRect

    public init(source: CaptureSource, rect: NormalizedRect) {
        self.source = source
        self.rect = rect
    }

    /// This tile's own name: which source, and where it sits. The rectangle is part of it, and the
    /// numbers are rounded to a thousandth, because a rect that has been through floating-point
    /// arithmetic on both ends is not bit-for-bit what was sent.
    var stableID: String {
        func thousandths(_ value: Double) -> Int { Int((value * 1000).rounded()) }
        let rect = rect.clamped
        return "\(source.stableID)@\(thousandths(rect.x)),\(thousandths(rect.y)),"
            + "\(thousandths(rect.width)),\(thousandths(rect.height))"
    }
}

/// A picture of one source, for the picker's grid.
///
/// A photograph taken when the host was asked, not a live view, the same idea as ``SpacePreview``
/// one level down. An application's thumbnail is a picture of its windows, so the tile answers what
/// this app is showing rather than only what it is called. JPEG rather than PNG, for the reason
/// ``SpacePreview`` gives.
public struct SourceThumbnail: Codable, Sendable, Equatable, Hashable {
    /// The largest thumbnail worth carrying: the catalogue is re-sent whenever anything in it
    /// changes, so one pathological thumbnail is a cost paid on every push. Half what a desktop
    /// preview is allowed, because this one is drawn in a grid tile rather than across a panel.
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
    /// ``CaptureSourceDescriptor/init(from:)``.
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

/// One entry in the list of things the host can capture, as pushed to the client. The host enumerates
/// its own reality and the client renders whatever it is given, so nothing here is hardcoded on the
/// client.
public struct CaptureSourceDescriptor: Codable, Sendable, Identifiable, Hashable {
    /// Icons are PNGs rendered by the host at picker size, and this is a hard ceiling: the whole
    /// catalogue is one control message. Kept in step with the render size, since the host draws them
    /// at 128 pixels, where an ordinary application's artwork lands near 20 KB.
    public static let maximumIconByteCount = 48 * 1_024

    public enum Kind: String, Codable, Sendable {
        case display, application, window
    }

    public let id: String
    public let kind: Kind
    /// Primary label: "Built-in Display", "Xcode", "ContentView.swift".
    public let title: String
    /// Secondary label: "2560×1440", "3 windows".
    public let subtitle: String?
    /// Present for application and application-owned window rows when macOS exposes it.
    public let bundleIdentifier: String?
    /// A small, render-ready PNG. `nil` means the client should use its fallback symbol.
    public let iconPNGData: Data?
    /// A photograph of this source's content, or `nil` when the host has not taken one.
    ///
    /// Only ever set for an application, and absent is the ordinary state: the host takes these when
    /// a client about to draw them asks, so a tile is briefly its own outline and then fills in.
    ///
    /// A separate field from ``iconPNGData``: that says what this application is, this says what it
    /// is showing.
    public let thumbnail: SourceThumbnail?
    public let source: CaptureSource
    /// Real pixel dimensions of the captured content, not points: `SCDisplay.width`/`height` report
    /// points, so a 5K panel reports half its actual width. This feeds the normalized→pixel mapping,
    /// and getting it wrong drifts the remote cursor on Retina displays.
    public let pixelSize: CGSize
    /// Whether this display is one the host process itself made, and so one a client may ask the
    /// host to remove with ``RemoteCommand/removeVirtualDisplay(displayID:)``.
    ///
    /// `false` for every other kind of row: a physical monitor and a window are never removable
    /// this way, and defaulting `false` here (and on decode, for a payload sent before this field
    /// existed) means an older host's rows read as ordinary and offer no remove control at all.
    public let isManagedVirtualDisplay: Bool
    /// Whether this display exists only in software — this host's own switch-made display as
    /// well as every phone-managed one, which is the broader question ``isManagedVirtualDisplay``
    /// does not answer: that one is true only for a display *this phone* may remove, and false
    /// for the switch-made one even though it is exactly as virtual. A client that only had that
    /// flag to go on could not tell a software display it may not touch from a real monitor, and
    /// the two read as the same row.
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

    /// This descriptor with a thumbnail attached, or itself when there is none. A modifier rather
    /// than an initializer argument, because the pictures are taken later, off the capture path.
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

/// One display's desktops, and which of them is on screen. Spaces are per-display, identified by the
/// pair (display, position in that display's ordered list), so two displays can each have a
/// "Desktop 1".
public struct SpaceDisplay: Codable, Sendable, Equatable, Identifiable {
    /// `CGDirectDisplayID`'s raw value, the same platform-neutral convention as
    /// ``CaptureSource/display(_:)``, and the value a client needs to build one.
    public let displayID: UInt32

    /// How many Spaces this display has. Sent rather than counted from ``previews``, which is
    /// sparse: a desktop never visited since the host started still has to be offered.
    public let count: Int

    /// 1-based index of this display's active desktop, in this display's own numbering, or `nil`
    /// when the display is showing a fullscreen application, where no desktop is current.
    public let current: Int?

    /// This display's desktops, as the host last saw them. Sparse on purpose: a Space with no entry
    /// has never been visited since the host started, or could not be captured.
    public let previews: [SpacePreview]

    public var id: UInt32 { displayID }

    public init(displayID: UInt32, count: Int, current: Int?, previews: [SpacePreview] = []) {
        self.displayID = displayID
        self.count = count
        self.current = current
        self.previews = previews
    }

    /// The preview for a 1-based index within this display, if the host has one.
    public func preview(for index: Int) -> SpacePreview? {
        previews.first { $0.index == index }
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, count, current, previews
    }

    /// Lenient about `previews` for the same reason ``SpaceInfo`` is: one missing thumbnail is not
    /// worth the catalogue.
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

    /// Derived from the main display, for the readers that predate multiple displays.
    public var count: Int { displays.first?.count ?? 0 }
    public var current: Int? { displays.first?.current }
    /// Every display's previews, flattened.
    public var previews: [SpacePreview] { displays.flatMap(\.previews) }
    /// Desktops across every display.
    public var totalCount: Int { displays.reduce(0) { $0 + $1.count } }

    /// Only the stored property, so `encode(to:)` can still be synthesised: the properties above are
    /// computed.
    private enum CodingKeys: String, CodingKey {
        case displays
    }

    /// The pre-multi-display shape. Read, never written.
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

/// One desktop, as the host last saw it.
///
/// A snapshot rather than a live view, and it has to be: ScreenCaptureKit captures what is on the
/// display, the other Spaces are not on it, and Mission Control's view is built from window-server
/// calls no third-party app can make.
public struct SpacePreview: Codable, Sendable, Equatable, Identifiable {
    /// 1-based, in the same numbering as ``SpaceInfo/current``.
    public let index: Int
    public let width: Int
    public let height: Int
    /// JPEG rather than PNG: a photograph of a screen drawn at a couple of hundred points.
    public let jpegData: Data

    public var id: Int { index }

    public init(index: Int, width: Int, height: Int, jpegData: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

/// The full set of capture sources the host is currently offering. Kept as a single value so it can
/// be pushed atomically; a client rendering a half-updated list would show entries it cannot select.
public struct CaptureCatalog: Codable, Sendable, Equatable {
    /// Keeps catalogue size predictable even on developer machines with huge app folders.
    ///
    /// The bound is real: every entry carries an icon of up to ``maximumIconByteCount``. Apple's
    /// applications under `/System/Applications` and in the App cryptex add around ninety titles, and
    /// the list is applied with `prefix`, so an overflow drops by alphabet.
    public static let maximumInstalledApplicationCount = 250
    public let displays: [CaptureSourceDescriptor]
    public let applications: [CaptureSourceDescriptor]
    public let windows: [CaptureSourceDescriptor]
    public let installedApplications: [InstalledApplicationDescriptor]
    /// Desktop Spaces info, if the host could read it.
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
