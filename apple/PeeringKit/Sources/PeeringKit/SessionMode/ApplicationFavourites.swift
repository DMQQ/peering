import Foundation

/// The apps a person pinned for one Mac, in the order they pinned them, kept per Mac because each has its own apps.
public struct ApplicationFavourites {
    private let defaults: UserDefaults
    private let key: String

    public init(hostID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "Peering.applicationFavourites.\(hostID)"
    }

    public var bundleIdentifiers: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func contains(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Adds it at the end, or takes it out if it is already there.
    public func toggle(_ bundleIdentifier: String) {
        var list = bundleIdentifiers
        if let index = list.firstIndex(of: bundleIdentifier) {
            list.remove(at: index)
        } else {
            list.append(bundleIdentifier)
        }
        defaults.set(list, forKey: key)
    }
}

/// Splits a Mac's apps into the three groups the apps sheet shows: pinned first, then running, then the rest of what is installed. Each app appears once, in the first group that claims it.
public struct ApplicationSections<App: Sendable>: Sendable {
    public let favourites: [App]
    public let running: [App]
    public let installed: [App]

    public init(
        favourites order: [String],
        running: [App],
        installed: [App],
        bundleIdentifier: (App) -> String?
    ) {
        var byBundle: [String: App] = [:]
        for app in installed + running {
            if let bundle = bundleIdentifier(app) { byBundle[bundle] = app }
        }
        let favourites = order.compactMap { byBundle[$0] }
        var shown = Set(order.filter { byBundle[$0] != nil })

        let runningLeft = running.filter { app in
            guard let bundle = bundleIdentifier(app) else { return true }
            return shown.insert(bundle).inserted
        }
        let installedLeft = installed.filter { app in
            guard let bundle = bundleIdentifier(app) else { return false }
            return shown.insert(bundle).inserted
        }
        self.favourites = favourites
        self.running = runningLeft
        self.installed = installedLeft
    }
}
