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

    /// Stable string used as the `Identifiable` id and in persisted selections,
    /// so a client's chosen source survives a reconnect.
    public var stableID: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .application(let pid): return "application:\(pid)"
        case .window(let id): return "window:\(id)"
        }
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

/// The host's desktop Spaces, as reported by the private CGS API.
///
/// Populated on a best-effort basis: hosts that cannot read it (permission failure,
/// or a future macOS that removes the private API) send `nil`, and clients fall back
/// to the ← / → arrows without a visual indicator.
public struct SpaceInfo: Codable, Sendable, Equatable {
    /// Total number of Spaces configured in Mission Control.
    public let count: Int
    /// 1-based index of the currently active Space.
    public let current: Int
    /// What each Space looked like when the host last saw it.
    ///
    /// Sparse on purpose. A Space with no entry has never been visited since the host started,
    /// or could not be captured, and the client draws an empty tile for it — which is the truth.
    /// Carrying a placeholder image instead would be a picture of a desktop that was never on
    /// screen.
    public let previews: [SpacePreview]

    public init(count: Int, current: Int, previews: [SpacePreview] = []) {
        self.count = count
        self.current = current
        self.previews = previews
    }

    /// The preview for a 1-based Space index, if the host has one.
    public func preview(for index: Int) -> SpacePreview? {
        previews.first { $0.index == index }
    }

    private enum CodingKeys: String, CodingKey {
        case count, current, previews
    }

    /// Lenient about `previews`, for the same reason ``CaptureCatalog`` is lenient about its own
    /// fields: a host built before previews existed sends a count and an index and nothing else,
    /// and a synthesised decoder would throw on the missing key — taking the whole catalogue, and
    /// with it the session, down over a thumbnail.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        current = try container.decode(Int.self, forKey: .current)
        previews = try container.decodeIfPresent([SpacePreview].self, forKey: .previews) ?? []
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
    public static let maximumInstalledApplicationCount = 80
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
