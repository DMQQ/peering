import Foundation
import RemoteCore

public struct ApplicationGroup: Identifiable, Equatable, Sendable {
    /// Stable across catalogue rebuilds: the application's identifier, else the group's key.
    public let id: String

    /// `nil` when the catalogue does not list the owning application as capturable: the group is still drawn, only selecting the whole application is lost.
    public let application: CaptureSourceDescriptor?

    public let title: String

    public let iconPNGData: Data?

    public var bundleIdentifier: String? {
        application?.bundleIdentifier ?? windows.lazy.compactMap(\.bundleIdentifier).first
    }

    public let windows: [CaptureSourceDescriptor]

    public init(
        id: String,
        application: CaptureSourceDescriptor?,
        title: String,
        iconPNGData: Data?,
        windows: [CaptureSourceDescriptor]
    ) {
        self.id = id
        self.application = application
        self.title = title
        self.iconPNGData = iconPNGData
        self.windows = windows
    }

    public func narrowing(to windows: [CaptureSourceDescriptor]) -> ApplicationGroup {
        ApplicationGroup(
            id: id,
            application: application,
            title: title,
            iconPNGData: iconPNGData,
            windows: windows
        )
    }
}

public enum SourceGrouping {
    /// Driven by the windows: a group exists because something is in it, and every window offered is accounted for. Windows keep the catalogue's order.
    public static func applicationGroups(
        applications: [CaptureSourceDescriptor],
        windows: [CaptureSourceDescriptor]
    ) -> [ApplicationGroup] {
        // Matched on the key both lists can produce, not the application's row. See ``key(bundle:name:)``.
        var byKey: [String: CaptureSourceDescriptor] = [:]
        for application in applications {
            let key = key(bundle: application.bundleIdentifier, name: application.title)
            // First wins, as the host does when it dedupes its application list.
            if byKey[key] == nil { byKey[key] = application }
        }

        // Insertion order is the catalogue's order, so no second sort is needed.
        var order: [String] = []
        var grouped: [String: [CaptureSourceDescriptor]] = [:]
        for window in windows {
            // The bundle identifier is exact; the name is the host's own fallback when a process has none, so both ends group alike.
            let key = key(bundle: window.bundleIdentifier, name: window.subtitle)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(window)
        }

        return order.compactMap { key in
            guard let owned = grouped[key], let first = owned.first else { return nil }
            let application = byKey[key]
            let title = application?.title ?? first.subtitle ?? String(localized: "Windows")
            return ApplicationGroup(
                id: application?.id ?? "group:\(key)",
                application: application,
                title: title,
                iconPNGData: application?.iconPNGData ?? first.iconPNGData,
                windows: owned
            )
        }
    }

    /// The bundle identifier, else the lowercased name, as the host decides. Namespaced so a bundle identifier equal to some application's name cannot merge unrelated groups.
    private static func key(bundle: String?, name: String?) -> String {
        if let bundle, !bundle.isEmpty { return "b:\(bundle)" }
        return "n:\((name ?? "").lowercased())"
    }
}
