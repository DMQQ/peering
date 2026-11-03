import Foundation

/// One read per protected folder at a time. macOS asks once per top-level folder (Desktop, Documents, Downloads), and
/// every thread parked on the unanswered dialog got its own copy of it, so subfolders share the folder's slot.
public struct FolderAccessSlots: Sendable {
    public static let protectedFolders = ["Desktop", "Documents", "Downloads"]

    private var reading: Set<String> = []

    public init() {}

    /// The protected folder `path` lives under, or the standardized path when it is under none of them.
    public static func key(for path: String, home: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let homeRoot = (home as NSString).standardizingPath
        for folder in protectedFolders {
            let root = homeRoot + "/" + folder
            if standardized == root || standardized.hasPrefix(root + "/") { return root }
        }
        return standardized
    }

    /// True when the caller now holds the slot and should read; false while another read holds it.
    public mutating func claim(_ key: String) -> Bool {
        reading.insert(key).inserted
    }

    public mutating func release(_ key: String) {
        reading.remove(key)
    }

    public func isReading(_ key: String) -> Bool {
        reading.contains(key)
    }
}
