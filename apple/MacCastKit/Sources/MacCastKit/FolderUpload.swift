import Foundation
import RemoteCore

/// One thing in a folder on its way to the Mac.
public struct FolderUploadEntry: Identifiable, Equatable, Sendable {
    /// What became of this one entry.
    ///
    /// Per entry rather than per transfer: one unreadable file in a folder must not cost the rest.
    public enum Outcome: Equatable, Sendable {
        case waiting
        case done
        case failed(String)
        /// Not sent, and nothing went wrong: a symbolic link is a reference to somewhere else, and
        /// copying its target would copy something the user did not pick. See ``FolderWalk``.
        case skipped(String)
    }

    public let id = UUID()
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let source: URL?
    public let bytes: Int

    public var outcome: Outcome = .waiting

    public init(
        path: String,
        name: String,
        isFolder: Bool,
        source: URL?,
        bytes: Int,
        outcome: Outcome = .waiting
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.source = source
        self.bytes = bytes
        self.outcome = outcome
    }
}

public struct FolderUpload: Equatable {
    public let root: String
    public let listingFolder: String
    /// Everything to be made or sent, in the order it has to happen.
    public var entries: [FolderUploadEntry]
    public var next = 0

    public var isRunning = true

    public init(root: String, listingFolder: String, entries: [FolderUploadEntry]) {
        self.root = root
        self.listingFolder = listingFolder
        self.entries = entries
    }

    public var isFinished: Bool { next >= entries.count }

    /// Everything that did not arrive, whether it went wrong or was never going to.
    public var problems: [FolderUploadEntry] { entries.filter { entry in
        guard !entry.isFolder else { return false }
        switch entry.outcome {
        case .done, .waiting: return false
        case .failed, .skipped: return true
        }
    } }

    public var sent: Int { entries.filter { !$0.isFolder && $0.outcome == .done }.count }
    public var fileCount: Int { entries.count { !$0.isFolder } }

    /// What to say about this run, in one line.
    public func line(limit: Int = 3) -> String {
        let total = fileCount

        guard isFinished else {
            let sending = entries.prefix(next).last { $0.outcome == .waiting }
                ?? entries.first { $0.outcome == .waiting }
            return String(localized: "Sending \(sent) of \(total)… \(sending?.name ?? "")")
        }

        let problems = self.problems
        guard !problems.isEmpty else { return String(localized: "Sent \(sent) of \(total).") }

        let names = problems.prefix(limit).map(\.name).joined(separator: ", ")
        let rest = problems.count > limit ? String(localized: " and \(problems.count - limit) more") : ""
        return String(localized: "Sent \(sent) of \(total). Could not send \(names)\(rest).")
    }
}

public enum FolderWalk {
    /// Every entry inside `root`, in the order it has to be sent.
    public static func entries(of root: URL, at destination: String) throws -> [FolderUploadEntry] {
        var found: [FolderUploadEntry] = []
        try append(contentsOf: root, to: &found, relative: "", destination: destination)
        return found
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    private static func append(
        contentsOf directory: URL,
        to found: inout [FolderUploadEntry],
        relative: String,
        destination: String
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )

        for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            let name = url.lastPathComponent
            let child = relative.isEmpty ? name : relative + "/" + name
            let path = childPath(child, of: destination)

            if values.isSymbolicLink == true {
                found.append(FolderUploadEntry(
                    path: path, name: name, isFolder: false, source: nil, bytes: 0,
                    outcome: .skipped("A link to somewhere else, which is not copied.")
                ))
                continue
            }

            guard values.isDirectory == true else {
                found.append(FolderUploadEntry(
                    path: path,
                    name: name,
                    isFolder: false,
                    source: url,
                    bytes: values.fileSize ?? 0
                ))
                continue
            }

            found.append(FolderUploadEntry(path: path, name: name, isFolder: true, source: nil, bytes: 0))
            let entry = found.count - 1
            do {
                try append(contentsOf: url, to: &found, relative: child, destination: destination)
            } catch {
                found[entry].outcome = .failed(error.localizedDescription)
            }
        }
    }
}
