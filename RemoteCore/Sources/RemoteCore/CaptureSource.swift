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
    public enum Kind: String, Codable, Sendable {
        case display, application, window
    }

    public let id: String
    public let kind: Kind
    /// Primary label: "Built-in Display", "Xcode", "ContentView.swift".
    public let title: String
    /// Secondary label: "2560×1440", "3 windows".
    public let subtitle: String?
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
        source: CaptureSource,
        pixelSize: CGSize
    ) {
        self.id = source.stableID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.pixelSize = pixelSize
    }
}

/// The full set of capture sources the host is currently offering.
///
/// Kept as a single value so it can be pushed atomically; a client that rendered a
/// half-updated list would show entries it cannot select.
public struct CaptureCatalog: Codable, Sendable, Equatable {
    public let displays: [CaptureSourceDescriptor]
    public let applications: [CaptureSourceDescriptor]
    public let windows: [CaptureSourceDescriptor]

    public init(
        displays: [CaptureSourceDescriptor] = [],
        applications: [CaptureSourceDescriptor] = [],
        windows: [CaptureSourceDescriptor] = []
    ) {
        self.displays = displays
        self.applications = applications
        self.windows = windows
    }

    public var all: [CaptureSourceDescriptor] { displays + applications + windows }

    public func descriptor(for source: CaptureSource) -> CaptureSourceDescriptor? {
        all.first { $0.source == source }
    }
}
