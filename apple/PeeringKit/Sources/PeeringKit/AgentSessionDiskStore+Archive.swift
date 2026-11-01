import Foundation

/// A retired chat is moved aside rather than deleted, and kept for a while in case it is wanted back.
extension AgentSessionDiskStore {
    public static let archiveLifetime: TimeInterval = 90 * 24 * 3600

    var archiveDirectory: URL {
        directory.appendingPathComponent("Archive", isDirectory: true)
    }

    /// Moves the chat's file into the archive, dated now so its lifetime there counts from retirement.
    public func archive(_ id: UUID, now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = archiveDirectory.appendingPathComponent("\(id.uuidString).json")
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: file(for: id), to: destination)
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
    }

    /// Deletes archived chats archived longer ago than the lifetime, and returns how many went.
    @discardableResult
    public func pruneArchive(now: Date = Date(), lifetime: TimeInterval = archiveLifetime) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: archiveDirectory.path) else { return 0 }
        var removed = 0
        for url in try manager.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
            guard now.timeIntervalSince(modified) > lifetime else { continue }
            try manager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    public func archivedIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory.path)) ?? []
        return names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }
    }
}
