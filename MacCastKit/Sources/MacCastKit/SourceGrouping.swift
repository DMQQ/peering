import Foundation
import RemoteCore

/// One application and the windows it owns, as the source picker draws them.
///
/// The picker's unit is an application, not a window: the catalogue offers the two as separate
/// flat lists, which is what the host can enumerate rather than what anybody is looking for.
/// An application with its windows under it is one thing to find and one thing to read.
public struct ApplicationGroup: Identifiable, Equatable, Sendable {
    /// Stable across catalogue rebuilds so a grid does not lose its state when an unrelated
    /// window opens: the application's own identifier when there is one, the group's key otherwise.
    public let id: String

    /// The catalogue's row for the application itself, when it offers one.
    ///
    /// `nil` for a window whose owning application the catalogue does not list as capturable. The
    /// group is still drawn, because a window the Mac is willing to capture is not something to
    /// hide over a missing header; what is lost is the ability to select the whole application.
    /// See ``SourceGrouping/applicationGroups(applications:windows:)``.
    public let application: CaptureSourceDescriptor?

    /// What to call the group: the application's own name where there is one.
    public let title: String

    /// The application's icon, falling back to its windows': a window carries its owning
    /// application's icon, so a group always has one if the Mac sent any at all.
    public let iconPNGData: Data?

    /// That application's windows, in the order the catalogue lists them.
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

    /// The same group with a different set of windows.
    ///
    /// For the picker's search, which keeps a group's heading and narrows what is under it, so a
    /// window found by name is not stranded under a heading nobody typed.
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

/// Turning the catalogue's two flat lists into the one grouping the picker draws.
///
/// A free function over two arrays rather than a method on the catalogue, because the interesting
/// cases are all mismatches, and those can be written down and run without a Mac or a session.
public enum SourceGrouping {
    /// The applications, each with its own windows, in the order the picker should show them.
    ///
    /// Driven by the windows and not by the applications: what the user is choosing between is the
    /// windows, and a group exists because there is something in it, so an application with no
    /// windows under it would be a heading over nothing. Every window the catalogue offers is
    /// accounted for, which is the property that matters. The windows keep the catalogue's order,
    /// which is the application's name and then the window's own title.
    public static func applicationGroups(
        applications: [CaptureSourceDescriptor],
        windows: [CaptureSourceDescriptor]
    ) -> [ApplicationGroup] {
        // Matched on the key both lists can produce for the same application, rather than on the
        // application's row: a window and an application row both know the owner's bundle
        // identifier and name. See ``key(bundle:name:)``.
        var byKey: [String: CaptureSourceDescriptor] = [:]
        for application in applications {
            let key = key(bundle: application.bundleIdentifier, name: application.title)
            // First wins, which is the same rule the host applies when it dedupes its own
            // application list, so the two agree about which row a window belongs to.
            if byKey[key] == nil { byKey[key] = application }
        }

        // Insertion order is the catalogue's order, so the groups come out sorted by application
        // name without a second sort here, and a group's windows stay in the order they arrived.
        var order: [String] = []
        var grouped: [String: [CaptureSourceDescriptor]] = [:]
        for window in windows {
            // A window names its owner twice and the bundle identifier is the exact one; the
            // name is what the host itself falls back to when a process has no identifier, so
            // both ends group the same way.
            let key = key(bundle: window.bundleIdentifier, name: window.subtitle)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(window)
        }

        return order.compactMap { key in
            guard let owned = grouped[key], let first = owned.first else { return nil }
            let application = byKey[key]
            // The application's name where there is one, and the window's own record of it
            // otherwise, which is the same string the host put there for this purpose.
            let title = application?.title ?? first.subtitle ?? "Windows"
            return ApplicationGroup(
                id: application?.id ?? "group:\(key)",
                application: application,
                title: title,
                iconPNGData: application?.iconPNGData ?? first.iconPNGData,
                windows: owned
            )
        }
    }

    /// What two rows of different lists have in common when they are about the same application.
    ///
    /// The bundle identifier when there is one, and the lowercased name when there is not, matching
    /// how the host decides two rows are the same application. The two are namespaced rather than
    /// compared directly, because a bundle identifier that happened to equal some application's
    /// name would otherwise merge two unrelated groups.
    private static func key(bundle: String?, name: String?) -> String {
        if let bundle, !bundle.isEmpty { return "b:\(bundle)" }
        return "n:\((name ?? "").lowercased())"
    }
}
