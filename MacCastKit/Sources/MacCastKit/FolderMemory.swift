import Foundation

/// The folder the Files browser was last in, kept per Mac so a reconnect lands there instead of at the home folder.
public struct FolderMemory {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "Peering.lastFilesFolders") {
        self.defaults = defaults
        self.key = key
    }

    public func folder(for mac: String) -> String? {
        stored[mac]
    }

    public func remember(_ path: String, for mac: String) {
        guard path.hasPrefix("/"), stored[mac] != path else { return }
        var all = stored
        all[mac] = path
        defaults.set(all, forKey: key)
    }

    public func forget(for mac: String) {
        var all = stored
        guard all.removeValue(forKey: mac) != nil else { return }
        defaults.set(all, forKey: key)
    }

    private var stored: [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
