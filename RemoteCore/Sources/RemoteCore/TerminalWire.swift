import Foundation

public struct TerminalSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isRunning: Bool

    /// Optional so a Mac too old to send it reads as unknown. Without the grid a client lays history out at 80x24 and full-screen frames wrap beyond reflow.
    public let columns: Int?
    public let rows: Int?
    public let createdAt: Date?

    public init(
        id: UUID,
        name: String,
        isRunning: Bool,
        columns: Int? = nil,
        rows: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.columns = columns
        self.rows = rows
        self.createdAt = createdAt
    }
}

/// No path: it is the listing's path plus this name.
public struct RemoteDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    /// Whether the entry opens as a folder. True for a symbolic link that points at one, because
    /// that is the question a tap on the row is asking; ``isSymlink`` is what tells the two apart.
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let permissions: String
    public let modified: Date?

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool,
        size: Int64,
        permissions: String,
        modified: Date?
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.permissions = permissions
        self.modified = modified
    }
}

extension RemoteDirectoryEntry {
    /// Only a regular file counts: a symbolic link's own mode carries the execute bit whether or not
    /// the thing it points at does, so a link would be a run button that fails.
    public var isExecutable: Bool {
        let bits = Array(permissions)
        // Ten characters: the type, then owner, group and others, three each. Execute is the third
        // of each group, at 3, 6 and 9.
        guard bits.count == 10, bits[0] == "-" else { return false }
        // `x` is the ordinary spelling; `s` and `t` are setuid, setgid and sticky shown in its place
        // and appear only where the execute bit is set as well.
        func isExecuteMark(_ character: Character) -> Bool {
            character == "x" || character == "s" || character == "t"
        }
        return isExecuteMark(bits[3]) || isExecuteMark(bits[6]) || isExecuteMark(bits[9])
    }
}

/// Two cases and not ``RemoteFileKind``: that type answers "what are these bytes and how should
/// they be drawn", which is a question about a preview and has no answer for a folder.
public enum RemoteEntryKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

public enum RemoteFileOperation: Codable, Equatable, Sendable {
    case create(path: String, kind: RemoteEntryKind)
    /// A name, not a path: a rename that took a path could cross folders, which is a different
    /// feature. The two ends both hold ``RemoteFileName/isValid(_:)``, which refuses a slash.
    case rename(path: String, to: String)
    /// Recursive, and the recursion is the caller's decision: what arrives here has already been
    /// through a confirmation, and the host cannot ask again with nobody at its screen.
    case delete(path: String)
}

public enum TerminalRequest: Codable, Equatable, Sendable {
    case list
    /// Which coding-agent commands this Mac has installed. Sent only to a Mac that declared
    /// ``ServerHello/supportsAgentList``. Answered with ``TerminalEvent/agents(installed:)``.
    case agents
    case create
    case input(sessionID: UUID, data: Data)
    case resize(sessionID: UUID, columns: UInt16, rows: UInt16)
    case rename(sessionID: UUID, name: String)
    /// A name the terminal earns by being used: the last command sent to it. The host ignores
    /// this once the terminal has been named by hand.
    case retitle(sessionID: UUID, command: String)
    case close(sessionID: UUID)
    /// Sent only to a Mac that declared ``ServerHello/supportsFileBrowser``: an older host cannot decode it.
    case startBrowser(id: UUID)
    /// One folder's contents, for the file browser. `nil` means the Mac's home folder, the one path
    /// the phone cannot work out for itself; the answer carries the path it resolved to.
    case listDirectory(sessionID: UUID, path: String?)    /// A file's contents, for the browser's preview. Read-only, and bounded: see
    /// ``TerminalEvent/fileContents(sessionID:path:offset:totalBytes:data:isLast:)``.
    case readFile(sessionID: UUID, path: String)
    /// The size is declared up front, so a Mac that will not take a file that large can say so
    /// cheaply, and the file is not replaced until ``writeChunk(sessionID:path:data:isLast:)`` says
    /// the last piece arrived.
    case beginWrite(sessionID: UUID, path: String, totalBytes: Int)
    case writeChunk(sessionID: UUID, path: String, data: Data, isLast: Bool)
    case changeFile(sessionID: UUID, operation: RemoteFileOperation)
    /// The phone's APNs device token, sent once when the session becomes ready and again if it
    /// changes. The host stores it per client and uses it to wake the phone when a terminal needs
    /// attention and the phone is not reachable over the control channel.
    case registerPushToken(Data)
}

public enum TerminalAttentionKind: String, Codable, Equatable, Sendable {
    case confirmation
    case password
}

/// Terminal state and byte output sent by the host. Output remains bytes because a PTY may
/// split UTF-8 scalars between reads and emits ANSI control sequences by design.
public enum TerminalEvent: Codable, Equatable, Sendable {
    case snapshot([TerminalSessionInfo])
    case agents(installed: [String])
    case created(TerminalSessionInfo)
    case renamed(TerminalSessionInfo)
    case output(sessionID: UUID, data: Data)
    case attention(sessionID: UUID, kind: TerminalAttentionKind, message: String)
    case commandFinished(sessionID: UUID, command: String?, duration: TimeInterval, exitStatus: Int32)
    case exited(sessionID: UUID, status: Int32)
    case closed(sessionID: UUID)
    /// One folder's contents, sorted by the host (folders first, then names) so every client shows
    /// the same order without agreeing on how to compare strings. `truncated` says the host's entry
    /// cap was reached and there is more on disk than was sent.
    case directory(sessionID: UUID, path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    /// Chunked because this shares the control channel with every keystroke, and a single large
    /// frame is a long write that input queues behind. `totalBytes` is the size on disk, so offset
    /// plus length is what says a file was cut short.
    ///
    /// `kind` rides on every piece rather than only the first, the client's buffer not being a
    /// preview until it knows whether it holds text or a picture.
    case fileContents(
        sessionID: UUID,
        path: String,
        kind: RemoteFileKind,
        offset: Int,
        totalBytes: Int,
        data: Data,
        isLast: Bool
    )
    /// Not ``failed``, which lands on the terminal's tab instead.
    case browseFailure(sessionID: UUID, path: String, message: String)
    case wroteFile(sessionID: UUID, path: String, totalBytes: Int)
    /// Not ``browseFailure``, which is a file that could not be read and clears the panel; the right
    /// answer to a failed save is to leave the editor open on the text the user still has.
    case writeFailure(sessionID: UUID, path: String, message: String)
    /// `path` is the path the client sent, echoed back rather than reconstructed, because a client
    /// holding a path it built cannot recognise an answer spelled differently. For a rename that is
    /// the old path.
    case fileOperationDone(sessionID: UUID, path: String, note: String)
    case fileOperationFailure(sessionID: UUID, path: String, message: String)
    case failed(sessionID: UUID?, message: String)
}
