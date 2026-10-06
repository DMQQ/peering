import Foundation
import RemoteCore

/// One thing in a folder on its way to the Mac.
///
/// A flat list rather than a tree: the entries are sent in order, so the walk produces a folder
/// before anything inside it and a file is never written into one that does not exist yet.
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
    /// Where this entry goes on the Mac.
    public let path: String
    /// The name alone, for the list the user reads.
    public let name: String
    /// Whether this is a folder to make rather than a file to send.
    public let isFolder: Bool
    /// The local file, for a file. `nil` for a folder, which has no contents of its own.
    public let source: URL?
    /// How large the file is. Zero for a folder.
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

/// A folder on its way to the Mac, and how far it has got.
public struct FolderUpload: Equatable {
    /// The folder on the Mac all of this goes inside.
    public let root: String
    /// The folder to ask the Mac for again when the run finishes.
    ///
    /// Not the same as ``root``: a folder being sent creates a new one, so the list that has to
    /// change is the folder holding it, while dropped files land in the folder on screen.
    public let listingFolder: String
    /// Everything to be made or sent, in the order it has to happen.
    public var entries: [FolderUploadEntry]
    /// The next entry to send. Everything before it has an outcome.
    public var next = 0

    /// Whether this run is still going.
    ///
    /// Kept after the last entry rather than removed: what happened arrives when the run ends, and
    /// nothing else on the screen says it.
    public var isRunning = true

    public init(root: String, listingFolder: String, entries: [FolderUploadEntry]) {
        self.root = root
        self.listingFolder = listingFolder
        self.entries = entries
    }

    public var isFinished: Bool { next >= entries.count }

    /// Everything that did not arrive, whether it went wrong or was never going to.
    ///
    /// Over the files: a folder is not something the user chose to send, it is the shape the files
    /// need to arrive in, so whether it was made is not a fact about the transfer.
    public var problems: [FolderUploadEntry] { entries.filter { entry in
        guard !entry.isFolder else { return false }
        switch entry.outcome {
        case .done, .waiting: return false
        case .failed, .skipped: return true
        }
    } }

    /// How many files have arrived.
    public var sent: Int { entries.filter { !$0.isFolder && $0.outcome == .done }.count }
    /// How many files there are to send, which is the number the user recognises.
    public var fileCount: Int { entries.count { !$0.isFolder } }

    /// What to say about this run, in one line.
    ///
    /// The failures are named, up to `limit`: "2 skipped" on its own sends the user looking through
    /// a folder of three hundred for which two.
    public func line(limit: Int = 3) -> String {
        let total = fileCount

        guard isFinished else {
            // The last entry with no outcome is the one in flight: the index moves as the request
            // goes out rather than when the answer comes back, so `entries[next]` would name the
            // file after the one being sent.
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

/// Turning a folder on this phone into the list of things to make on the Mac.
public enum FolderWalk {
    /// Every entry inside `root`, in the order it has to be sent.
    ///
    /// Depth first, and load-bearing rather than incidental: a folder appears before anything inside
    /// it, because the transfer sends the list in order and a file cannot be written into a folder
    /// that does not exist yet. Sorted by name at every level, so two runs over the same folder
    /// produce the same list.
    ///
    /// Symbolic links are listed and skipped: following one would read a file the user did not pick,
    /// and copying the link itself needs a protocol this does not have.
    ///
    /// A readable folder whose contents cannot be read is an entry that failed, not a walk that
    /// stops: that subfolder's own entry carries the sentence and everything beside it still goes.
    /// Nothing is hidden, not dotfiles, not `.DS_Store`, not packages, so a `.app` goes as a folder
    /// of its parts.
    ///
    /// - Throws: only for a `root` that cannot be read at all, the one case where there is nothing
    ///   to say per entry.
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
            // A file that vanishes between the listing and the stat is passed over rather than
            // failing the walk: the user is mid-copy of a folder something else may be writing to.
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
