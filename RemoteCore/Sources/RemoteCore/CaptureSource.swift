import CoreGraphics
import Foundation

/// What the host is capturing.
///
/// Deliberately stores **platform-neutral raw values** rather than `CGDirectDisplayID`
/// or `CGWindowID`. Those types live in macOS-only headers, and this module compiles
/// for iOS too — naming them here would break the client build, which is the same
/// mistake that made the original `RemoteCommand` unusable on iOS.
public enum CaptureSource: Codable, Sendable, Hashable {
    /// A whole display. `UInt32` is a `CGDirectDisplayID` raw value.
    case display(UInt32)
    /// Every window belonging to one process, composited. `Int32` is a `pid_t`.
    case application(Int32)
    /// A single window. `UInt32` is a `CGWindowID` raw value.
    case window(UInt32)

    /// Several sources drawn into one picture, at the rectangles the client asked for.
    ///
    /// **The only source here that is not a source.** Everything else in this enum names
    /// something macOS is already showing; this one names a canvas the host builds out of
    /// several of them, because the phone has one video layer and cannot be sent N streams. The
    /// Mac opens one capture per distinct tile, draws each into its rectangle, and encodes the
    /// result once, so a mosaic costs one stream on the wire and several on the Mac.
    ///
    /// **It takes no input.** A tap in a mosaic is a tap on the arrangement rather than on the
    /// Mac, and what a tile's picture means as a coordinate depends on which tile it lands in.
    /// Selecting a tile is what gives a source back its input: the client asks for that source
    /// on its own, which is an ordinary source switch. See ``MosaicTile``.
    ///
    /// `pixelSize` is the canvas in pixels, chosen by the client from the screen it is drawing
    /// on and clamped by the host. `frameRate` is the canvas's own, which is not the setting a
    /// single source is streamed at: a mosaic is several captures composited per frame, so its
    /// rate is the one number that multiplies the host's whole cost.
    case mosaic(MosaicLayout)

    /// Stable string used as the `Identifiable` id and in persisted selections,
    /// so a client's chosen source survives a reconnect.
    public var stableID: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .application(let pid): return "application:\(pid)"
        case .window(let id): return "window:\(id)"
        case .mosaic(let layout):
            // **The canvas as well as the tiles.** Two arrangements of the same tiles at
            // different canvas sizes are two different pictures, and the tiles alone would give
            // them one name, which is the collision that makes a source switch silently not
            // happen. The frame rate is deliberately not here: redrawing the same arrangement
            // faster is the same arrangement.
            let name = "\(layout.canvas.width)x\(layout.canvas.height)"
                + layout.tiles.map { "|\($0.stableID)" }.joined()

            // Hashed by hand rather than with `Hasher`, which is seeded per process: this string
            // is what a persisted selection and ``PictureIdentity`` are kept by, and a name that
            // changed on every launch would make the same arrangement a new picture every time
            // the app opened. FNV-1a, the cheap one that is stable across processes forever.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in name.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return "mosaic:\(String(hash, radix: 16))"
        }
    }

    /// Whether this source is a canvas the host builds rather than something the Mac is showing.
    ///
    /// Asked in the two places the difference is not about pixels: the host refuses input while
    /// one is up, and the client's picker has no row to tick because a mosaic is never offered
    /// *by* the Mac, only asked for. Written as a property rather than as an `if case` at each
    /// of them so the reason lives in one place.
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
    /// The distinction decides where the input mapping comes from. A display is fixed for the
    /// life of the stream, so the geometry read once when capture starts stays true. An
    /// application or a window is dragged and resized by the user continuously and silently,
    /// so its answer goes stale the moment it is touched — and the only thing that observes the
    /// change is the per-frame content rect.
    public var contentMovesOnItsOwn: Bool {
        switch self {
        case .display: return false
        case .application, .window: return true
        // **A mosaic is a display, not a window.** Its canvas is a size the client asked for and
        // keeps until it asks for another one, while the tiles inside it come and go and their
        // windows are dragged around without the canvas changing shape at all. That is the same
        // rule a display follows, and it is the rule the client's zoom and pan want: a tile
        // resizing inside a fixed canvas is not a reason to throw away where the user was
        // looking, and a different arrangement is a different picture and is.
        case .mosaic: return false
        }
    }
}

/// A rectangle in the canvas's own space: (0,0) at the top left of the canvas and (1,1) at its
/// bottom right, whatever the canvas's aspect ratio.
///
/// **Normalized rather than in pixels**, for the same reason ``NormalizedPoint`` is: the client
/// decides how much of its screen a tile gets and the Mac decides what pixel size the canvas is
/// built at, so neither end can name the other's units. The host is the one that multiplies this
/// by the canvas's pixels when it composites, and the client is the one that multiplies it by
/// the picture's rect on screen when it draws the borders and hit-tests a tap.
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

    /// Clamped copy, so a layout can describe nothing outside the canvas it is drawn in.
    ///
    /// The width and the height are clamped first and the origin against what is left, rather
    /// than each of the four against 0…1: a rect of `x: 0.9, width: 0.5` clamped that way would
    /// run from 0.9 to 1.4 and be drawn past the edge of the canvas, which is the one thing a
    /// layout must not be able to do. A rect that is entirely outside clamps to nothing rather
    /// than to a corner.
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

    /// Whether a normalized point lands inside this rect.
    ///
    /// Half-open on the far edges, so the point where two tiles meet belongs to exactly one of
    /// them rather than to both, which is what a hit test has to answer.
    public func contains(_ point: NormalizedPoint) -> Bool {
        let rect = clamped
        return point.x >= rect.x && point.x < rect.x + rect.width
            && point.y >= rect.y && point.y < rect.y + rect.height
    }
}

/// What a mosaic is: the canvas it is drawn in, what sits on it, and how often it is redrawn.
///
/// The client builds one of these and sends it as a capture source; the host composites it. It
/// travels as one value rather than as three parameters because the canvas is part of what a
/// mosaic *is*: two layouts of the same tiles at different canvas sizes are two different
/// pictures, and ``CaptureSource/stableID`` has to tell them apart.
public struct MosaicLayout: Codable, Sendable, Equatable, Hashable {
    /// The most tiles one mosaic may have, and the number both ends read.
    ///
    /// **A limit on the Mac rather than on the phone.** Every tile is a ScreenCaptureKit stream
    /// of its own, so a mosaic is the one thing in this app that makes the host work N times as
    /// hard, and the client asking for it is a paired device rather than a trusted one. Six is
    /// where a 1080p canvas still gives each tile about 640×360, which is the point at which a
    /// tile is still readable on a phone; the host trims to it rather than refusing, so a
    /// request from a newer client is a smaller mosaic rather than no picture at all.
    public static let maximumTileCount = 6

    /// The most pixels a canvas may be built at, in total.
    ///
    /// The other half of the same limit, because the count alone bounds nothing: one tile over
    /// the whole of a 7680×4320 canvas is one stream and a quarter of a billion pixels per
    /// second to composite. 2560×1440 is twice a 1080p canvas and still less than the smallest
    /// display this app captures.
    public static let maximumCanvasPixels = 2560 * 1440

    /// The canvas in pixels, as the client wants it drawn on its own screen.
    public let canvas: CGSize
    public let tiles: [MosaicTile]
    /// How often the canvas is redrawn, which is every tile's frame rate as well as the
    /// encoder's. See ``minimumFrameRate``.
    public let frameRate: Int

    /// **A mosaic's frame rate is its cost, multiplied.** Six tiles composited at 60 is six
    /// captures and six composites per frame at 60, which is a Mac doing nothing else. The
    /// floor is what still reads as motion; the ceiling is what a laptop should be asked for.
    public static let minimumFrameRate = 5
    public static let maximumFrameRate = 30

    public init(canvas: CGSize, tiles: [MosaicTile], frameRate: Int) {
        self.canvas = canvas
        self.tiles = tiles
        self.frameRate = frameRate
    }

    /// What a host will actually build, or `nil` when there is no mosaic in this at all.
    ///
    /// **Trimmed rather than refused**, and this is the whole of the host's defence: the layout
    /// arrives from a device the Mac has paired with and does not control, and a request that
    /// names twenty tiles or a wall-sized canvas is a Mac asked to melt. Trimming keeps the
    /// picture honest (the first tiles are the ones the user put there), keeps the limits in one
    /// place both ends read, and means a client that is newer than its Mac gets a smaller mosaic
    /// rather than an error it cannot do anything about.
    ///
    /// The canvas is clamped by area rather than by each side, so an odd aspect ratio is kept:
    /// a 4000×300 canvas is trimmed to fit the budget, not reshaped into a television.
    public var validated: MosaicLayout? {
        guard !tiles.isEmpty else { return nil }

        let width = max(2, canvas.width.rounded(.down))
        let height = max(2, canvas.height.rounded(.down))
        let pixels = width * height
        let budget = CGFloat(Self.maximumCanvasPixels)
        let scale = pixels > budget ? (budget / pixels).squareRoot() : 1
        // Even, because the encoder rounds down to even and the client's tile rects were
        // measured against what it asked for: an odd canvas is a picture a pixel narrower than
        // the one the tiles describe. Halved and floored rather than divided by two and
        // multiplied back, which in floating point leaves an odd number odd.
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

    /// This tile's own name: which source, and where it sits.
    ///
    /// The rectangle is part of it because two tiles of one source in two places are two tiles,
    /// and an arrangement that moved one of them is a different arrangement from the one a zoom
    /// and a pan were chosen against.
    ///
    /// The numbers are rounded to a thousandth before they are printed, because a rect that has
    /// been through floating-point arithmetic twice, once on each end, is not bit-for-bit the
    /// rect that was sent: without this, a layout would be a slightly different name each time
    /// it made the round trip, and the client would treat its own arrangement as a new picture.
    var stableID: String {
        func thousandths(_ value: Double) -> Int { Int((value * 1000).rounded()) }
        let rect = rect.clamped
        return "\(source.stableID)@\(thousandths(rect.x)),\(thousandths(rect.y)),"
            + "\(thousandths(rect.width)),\(thousandths(rect.height))"
    }
}

/// One entry in the list of things the host can capture, as pushed to the client.
///
/// The host enumerates its own reality (displays attached, apps running, windows open)
/// and the client renders whatever it is given, so the picker stays honest as that
/// reality changes. Nothing here is hardcoded on the client.
public struct CaptureSourceDescriptor: Codable, Sendable, Identifiable, Hashable {
    /// Icons are PNGs rendered by the host at picker size. Keeping a hard ceiling here
    /// prevents an application with a pathological icon from turning one catalogue into a
    /// multi-megabyte control message.
    public static let maximumIconByteCount = 8 * 1_024

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
    public let source: CaptureSource
    /// Real pixel dimensions of the captured content — **not** points.
    ///
    /// `SCDisplay.width`/`height` report points; a 5K panel would report half its
    /// actual width. This feeds the normalized→pixel mapping, so getting it wrong
    /// makes the remote cursor drift on Retina displays.
    public let pixelSize: CGSize

    public init(
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        bundleIdentifier: String? = nil,
        iconPNGData: Data? = nil,
        source: CaptureSource,
        pixelSize: CGSize
    ) {
        self.id = source.stableID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.bundleIdentifier = bundleIdentifier
        self.iconPNGData = Self.boundedIcon(iconPNGData)
        self.source = source
        self.pixelSize = pixelSize
    }

    private static func boundedIcon(_ data: Data?) -> Data? {
        guard let data, data.count <= maximumIconByteCount else { return nil }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, bundleIdentifier, iconPNGData, source, pixelSize
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

/// An installed GUI application that is not currently a capturable process.
///
/// It deliberately has no `CaptureSource`: a PID only exists after launch. The client asks
/// the host to launch this bundle identifier, then the live catalogue supplies the real PID.
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

/// One display's desktops, and which of them is on screen.
///
/// Spaces are per-display: the window server keeps a separate ordered list for every screen, so
/// a desktop is only ever identified by the pair (*display*, position in that display's list).
/// A Mac with 2 desktops on its built-in screen and 3 on a second one has five desktops and two
/// of them are called "Desktop 1" — which is why the display is part of the type rather than a
/// label hung on a flat list.
public struct SpaceDisplay: Codable, Sendable, Equatable, Identifiable {
    /// `CGDirectDisplayID`'s raw value, the same platform-neutral convention as
    /// ``CaptureSource/display(_:)`` — and the value a client needs to build one.
    public let displayID: UInt32

    /// How many Spaces this display has.
    ///
    /// Sent rather than counted from ``previews``, which is sparse by design: a desktop never
    /// visited since the host started has no picture and still has to be offered.
    public let count: Int

    /// 1-based index of this display's active **desktop**, in this display's own numbering, or
    /// `nil` when the display is showing a fullscreen application.
    ///
    /// `nil` rather than a fallback, because there genuinely is no current desktop then. A
    /// number picked to fill the gap would mark a desktop as current that nobody is looking at,
    /// which is the same lie in the other direction — and this field drives the one highlight
    /// in the panel.
    public let current: Int?

    /// This display's desktops, as the host last saw them.
    ///
    /// Sparse on purpose. A Space with no entry has never been visited since the host started,
    /// or could not be captured, and the client draws an empty tile for it — which is the truth.
    /// Carrying a placeholder image instead would be a picture of a desktop that was never on
    /// screen.
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

    /// Lenient about `previews` for the same reason ``SpaceInfo`` is lenient about its own
    /// fields: one missing thumbnail is not worth the catalogue.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        count = try container.decode(Int.self, forKey: .count)
        // Absent means a fullscreen application is on screen, which is a fact rather than a
        // missing field — hence `IfPresent` and no fallback.
        current = try container.decodeIfPresent(Int.self, forKey: .current)
        previews = try container.decodeIfPresent([SpacePreview].self, forKey: .previews) ?? []
    }
}

/// Every display's desktops, as reported by the private CGS API.
///
/// Populated on a best-effort basis: hosts that cannot read the Space lists (permission failure,
/// or a future macOS that removes the private API) send `nil`, and clients fall back
/// to the ← / → arrows without a visual indicator.
public struct SpaceInfo: Codable, Sendable, Equatable {
    /// One entry per display, **main display first**.
    ///
    /// The ordering is load-bearing rather than incidental: every property below that predates
    /// this type described the main display, and reading the first entry is what keeps them
    /// meaning that.
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

    /// Only the stored property, so `encode(to:)` can still be synthesised — the three
    /// properties above are computed and have nothing of their own to write.
    private enum CodingKeys: String, CodingKey {
        case displays
    }

    /// The pre-multi-display shape. Read, never written.
    private enum LegacyCodingKeys: String, CodingKey {
        case count, current, previews
    }

    /// Lenient in both directions, for the same reason ``CaptureCatalog`` is lenient about its
    /// own fields: a payload from a host built before this type described more than one display
    /// carries a flat `count`/`current`/`previews` and no `displays` key at all, and a
    /// synthesised decoder would throw on the missing key — taking the whole catalogue, and with
    /// it the session, down over a thumbnail.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let displays = try container.decodeIfPresent([SpaceDisplay].self, forKey: .displays) {
            self.displays = displays
            return
        }

        // The old shape, synthesised into one display. `displayID` is 0 because that payload
        // never carried one: there is no display to name, so the client's fallback label and a
        // switch the host will decline are both better than refusing to decode the catalogue.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.displays = [
            SpaceDisplay(
                displayID: 0,
                count: try legacy.decode(Int.self, forKey: .count),
                // Decoded as present because the old shape predates fullscreen Spaces being
                // distinguished at all, so it always carried one.
                current: try legacy.decodeIfPresent(Int.self, forKey: .current),
                previews: try legacy.decodeIfPresent([SpacePreview].self, forKey: .previews) ?? []
            )
        ]
    }
}

/// One desktop, as the host last saw it.
///
/// A snapshot rather than a live view, and it has to be: ScreenCaptureKit captures what is on
/// the display, and the other Spaces are by definition not on it. What Mission Control shows is
/// built from window-server calls no third-party app can make, so this is the honest version —
/// each tile is that desktop at the moment the user left it.
public struct SpacePreview: Codable, Sendable, Equatable, Identifiable {
    /// 1-based, in the same numbering as ``SpaceInfo/current``.
    public let index: Int
    public let width: Int
    public let height: Int
    /// JPEG rather than PNG: this is a photograph of a screen, the tile is a couple of hundred
    /// points wide, and PNG of the same frame costs several times as much to say the same thing.
    public let jpegData: Data

    public var id: Int { index }

    public init(index: Int, width: Int, height: Int, jpegData: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

/// The full set of capture sources the host is currently offering.
///
/// Kept as a single value so it can be pushed atomically; a client that rendered a
/// half-updated list would show entries it cannot select.
public struct CaptureCatalog: Codable, Sendable, Equatable {
    /// Keeps catalogue size predictable even on developer machines with huge app folders.
    ///
    /// **Once 80, and that stopped being enough the day the system domain was searched.** Apple's
    /// own applications live under `/System/Applications` and in the App cryptex, so a machine that
    /// listed 26 third-party apps now lists around ninety with Apple's among them. The list is
    /// applied with `prefix`, so the overflow was dropped by alphabet rather than by anything
    /// meaningful — the last few titles simply were not there, with nothing said.
    ///
    /// Raised rather than removed, because the bound is real: every entry carries an icon of up to
    /// ``maximumIconByteCount``, and the catalogue is rebuilt whenever an application launches or
    /// quits. The host logs when this bites, so a truncation is never silent again.
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

    /// A defensive view for clients receiving a catalogue from an older or custom host
    /// which may put a running bundle in both sections.
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
