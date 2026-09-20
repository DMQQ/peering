import Foundation
import RemoteCore

/// One thing in a folder on its way to the Mac.
///
/// **A flat list rather than a tree, and the order is what makes it work.** The entries are sent one
/// after another, and a file cannot be written into a folder that does not exist yet, so the walk
/// produces a folder before anything inside it and the transfer just follows the list. A tree would
/// carry the same information and would need walking again at every step to find out what to do
/// next.
///
/// **In `MacCastKit` rather than in the app**, like every other rule that can be wrong silently:
/// whether a file's path is what it should be, and whether a folder's contents are counted as the
/// folder's fault, are both questions with answers nothing on screen would tell you were wrong.
public struct FolderUploadEntry: Identifiable, Equatable, Sendable {
    /// What became of this one entry.
    ///
    /// **Per entry rather than per transfer, which is the whole point.** One file in a folder of
    /// two hundred being unreadable, or too large to send, must not cost the other hundred and
    /// ninety-nine: the folder still arrives, minus one thing, and the user is told which thing and
    /// why. A transfer with one outcome for the lot would either stop at the first problem or
    /// report success over a folder that is missing a file.
    public enum Outcome: Equatable, Sendable {
        case waiting
        case done
        case failed(String)
        /// Not sent, and nothing went wrong: a symbolic link is a reference to somewhere else and
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
    /// Everything to be made or sent, in the order it has to happen.
    public var entries: [FolderUploadEntry]
    /// The next entry to send. Everything before it has an outcome.
    public var next = 0

    /// Whether this run is still going.
    ///
    /// **Kept after the last entry rather than removed**, because the answer to "what happened"
    /// arrives when the run ends and there is nothing else on the screen that would say it: the
    /// folder looks the way it did, and two files are quietly missing from it. What the user is
    /// shown until they go somewhere else is the line below.
    public var isRunning = true

    public init(root: String, entries: [FolderUploadEntry]) {
        self.root = root
        self.entries = entries
    }

    public var isFinished: Bool { next >= entries.count }

    /// Everything that did not arrive, whether it went wrong or was never going to.
    ///
    /// **Over the files, and the folders are left out of it.** A folder is not something the user
    /// chose to send: it is the shape the files need to arrive in, and the transfer has to make one
    /// before it can write inside it. So whether a folder was made or was already there is not a
    /// fact about the transfer, and reporting it would be the app answering a question nobody
    /// asked. What the user picked is the files, and each of those says for itself whether it
    /// landed. A folder that could not be made at all is still visible: every file inside it fails,
    /// with the Mac's own reason, and they are named.
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
    /// Two sentences rather than one with a clause: while it is going, where it has got to and what
    /// it is on; when it has stopped, what the whole thing came to. **The failures are named**, up
    /// to a few, because "2 skipped" on its own sends the user looking through a folder of three
    /// hundred for which two, and naming them all would be a paragraph in a line that has one row.
    public func line(limit: Int = 3) -> String {
        let total = fileCount

        guard isFinished else {
            // **The last entry with no outcome is the one in flight**, because the index moves as
            // the request goes out rather than when the answer comes back. Naming `entries[next]`
            // would name the file *after* the one being sent, which is the kind of small wrong
            // nobody reports and everybody notices.
            let sending = entries.prefix(next).last { $0.outcome == .waiting }
                ?? entries.first { $0.outcome == .waiting }
            return "Sending \(sent) of \(total)… \(sending?.name ?? "")"
        }

        let problems = self.problems
        guard !problems.isEmpty else { return "Sent \(sent) of \(total)." }

        let names = problems.prefix(limit).map(\.name).joined(separator: ", ")
        let rest = problems.count > limit ? " and \(problems.count - limit) more" : ""
        return "Sent \(sent) of \(total). Could not send \(names)\(rest)."
    }
}

/// Turning a folder on this phone into the list of things to make on the Mac.
public enum FolderWalk {
    /// Every entry inside `root`, in the order it has to be sent.
    ///
    /// **Depth first, and that is load-bearing rather than incidental.** A folder appears in the
    /// list before anything inside it, because the transfer sends the list in order and a file
    /// cannot be written into a folder that does not exist yet.
    ///
    /// **Sorted by name at every level**, so two runs over the same folder produce the same list.
    /// `FileManager`'s enumeration order is the filesystem's business and differs between a folder
    /// that has just been written and one that has been sitting there, which would make a failure
    /// the user reports one nobody could reproduce.
    ///
    /// **Symbolic links are listed and skipped.** Following one would read a file the user did not
    /// pick, and copying the link itself needs a protocol this does not have. It is an entry with
    /// an outcome rather than an omission, because a folder that arrives one file short and says so
    /// is a folder the user can trust; one that arrives short in silence is not.
    ///
    /// **A readable folder whose contents cannot be read is an entry that failed**, not a walk that
    /// stops: that subfolder's own entry carries the sentence, and everything beside it still goes.
    ///
    /// **Nothing is hidden.** Not dotfiles, not `.DS_Store`, not packages: a copied folder is the
    /// folder, and a walk that quietly left things out would be the app deciding which of the user's
    /// own files they meant. What it means is that a `.app` or a `.rtfd` goes as a folder of its
    /// parts, which is what it is on disk.
    ///
    /// - Throws: only for a `root` that cannot be read at all, which is the caller's own folder and
    ///   the one case where there is nothing to say per entry.
    public static func entries(of root: URL, at destination: String) throws -> [FolderUploadEntry] {
        var found: [FolderUploadEntry] = []
        try append(contentsOf: root, to: &found, relative: "", destination: destination)
        return found
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    /// Walks one directory, in name order, adding a folder before the things inside it.
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
            // failing the walk: it is one entry, and the user is mid-copy of a folder something
            // else may be writing to.
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
