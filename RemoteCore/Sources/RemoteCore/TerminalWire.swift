import Foundation

/// A terminal owned by the Mac host. The identifier remains stable while the control client
/// disconnects, allowing a later authenticated connection to reattach to the same process.
public struct TerminalSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isRunning: Bool

    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }
}

/// One entry in a directory listing.
///
/// Name, type and a little metadata rather than a path: the path is the one the listing was
/// asked for plus this name, and sending it per entry would be the same string a thousand times
/// — see ``TerminalRequest/listDirectory(sessionID:path:)``.
public struct RemoteDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    /// Whether the entry opens as a folder. True for a symbolic link that points at one, because
    /// that is the question a tap on the row is asking; ``isSymlink`` is what tells the two apart.
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// The entry's own size, which is what `ls -l` prints beside it: the bytes a file holds, or
    /// for a directory the bytes its own entry takes. Deliberately **not** a walk of what is
    /// inside a folder — that is a number nobody asked the disk for, it costs a tree read per row
    /// to get, and `ls -l` does not print it either.
    ///
    /// Zero where the provider could not say, which is the one listing that answers with names
    /// alone — see ``permissions``.
    public let size: Int64
    /// The mode bits in the form `ls -l` prints them, type character included: `-rw-r--r--`.
    /// One string rather than the nine booleans it would take to say the same thing in the wire
    /// format, and in the form the audience for it already reads.
    ///
    /// Empty where the provider could not say. The two are the same fact arrived at twice — every
    /// listing that stats an entry has both, and the `ls` fallback that has neither has neither —
    /// which is what lets a client tell "no size" from "zero bytes" without a third field.
    public let permissions: String
    /// When the Mac says it was last changed, and nothing when the filesystem would not say.
    /// Optional rather than a stand-in date, because a row reading "1 January 1" is worse than a
    /// row with no date on it.
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

/// Requests sent by an authenticated client over the control connection.
public enum TerminalRequest: Codable, Equatable, Sendable {
    case list
    /// A new login shell. It arrives unnamed: the host numbers it, and the terminal takes its
    /// name from the first command run in it.
    case create
    case input(sessionID: UUID, data: Data)
    case resize(sessionID: UUID, columns: UInt16, rows: UInt16)
    /// A name the user typed. It sticks, and nothing replaces it afterwards.
    case rename(sessionID: UUID, name: String)
    /// A name the terminal earns by being used: the last command sent to it. The host ignores
    /// this once the terminal has been named by hand.
    case retitle(sessionID: UUID, command: String)
    case close(sessionID: UUID)
    /// One folder's contents, for the file browser. `nil` means the Mac's home folder, which is
    /// the one path the phone cannot work out for itself — the answer carries the path it
    /// resolved to, and every request after the first names a path outright.
    case listDirectory(sessionID: UUID, path: String?)
    /// A file's contents, for the browser's preview. Read-only, and bounded: see
    /// ``TerminalEvent/fileContents(sessionID:path:offset:totalBytes:data:isLast:)``.
    case readFile(sessionID: UUID, path: String)
    /// Opening a file for writing, which replaces whatever was there.
    ///
    /// The size is declared before any of the file travels, so a Mac that will not take a file that
    /// large can say so while the answer is still cheap, and because the write is not committed
    /// until ``writeChunk(sessionID:path:data:isLast:)`` says the last piece has arrived, so a
    /// client that stops halfway must not leave a file half replaced.
    ///
    /// It carries no contents, which is what makes a save and an upload the same mechanism: an
    /// editor sending back text it already holds and a phone sending a file it just read both begin
    /// here, and neither is the host's business to tell apart.
    case beginWrite(sessionID: UUID, path: String, totalBytes: Int)
    /// A piece of a file being written.
    ///
    /// Chunked because the control channel caps a message at ``ProtocolInfo/maxControlPayload`` and
    /// a file is not a message. See the note on ``RemoteCommand`` for the same rule on the other
    /// side of this connection. Pieces arrive in order on a channel that does not reorder them, so
    /// the host appends rather than seeks, and the one marked last is where the file is either
    /// replaced or is not.
    case writeChunk(sessionID: UUID, path: String, data: Data, isLast: Bool)
}

public enum TerminalAttentionKind: String, Codable, Equatable, Sendable {
    case confirmation
    case password
}

/// Terminal state and byte output sent by the host. Output remains bytes because a PTY may
/// split UTF-8 scalars between reads and emits ANSI control sequences by design.
public enum TerminalEvent: Codable, Equatable, Sendable {
    case snapshot([TerminalSessionInfo])
    case created(TerminalSessionInfo)
    /// The terminal's name changed — by a command run in it, or by the user typing one.
    case renamed(TerminalSessionInfo)
    case output(sessionID: UUID, data: Data)
    case attention(sessionID: UUID, kind: TerminalAttentionKind, message: String)
    case exited(sessionID: UUID, status: Int32)
    case closed(sessionID: UUID)
    /// One folder's contents, sorted by the host — folders first, then names — so every client
    /// shows the same order without having to agree on how to compare strings. `truncated` says
    /// the host's entry cap was reached and there is more on disk than was sent.
    case directory(sessionID: UUID, path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    /// A file being previewed, in pieces.
    ///
    /// Chunked rather than sent as one payload, and the reason is the connection rather than the
    /// file: this shares the control channel with every keystroke, and a single large frame is a
    /// long write that input queues behind. `totalBytes` is the size on disk, so a client can say
    /// how much of a long file it is showing — offset plus length is what says it was cut short,
    /// which is why there is no separate flag for it.
    case fileContents(
        sessionID: UUID,
        path: String,
        offset: Int,
        totalBytes: Int,
        data: Data,
        isLast: Bool
    )
    /// A browse request that could not be answered: a folder that could not be read, or a file
    /// that could not be shown. Carries the path it was about, so the panel that asked can clear
    /// the right waiting state and leave the others alone.
    ///
    /// Deliberately not ``failed``: that one lands on the terminal's tab, and a folder the Mac
    /// will not open is not a fact about the shell.
    case browseFailure(sessionID: UUID, path: String, message: String)
    /// A file the client wrote is now on disk, at the size it ended up.
    ///
    /// The size is what the Mac counted rather than what the client said it was sending, so the two
    /// agreeing is the client's evidence that all of it arrived. There is no contents here: what is
    /// on disk now is a question the client asks with ``TerminalRequest/readFile(sessionID:path:)``,
    /// which is the same door it read the file through in the first place.
    case wroteFile(sessionID: UUID, path: String, totalBytes: Int)
    /// A write that did not happen.
    ///
    /// Deliberately not ``browseFailure``, which is a file that could not be *read*; that one
    /// clears the panel, and the right answer to a save that failed is to leave the editor open on
    /// the text the user still has and say what went wrong beside it.
    case writeFailure(sessionID: UUID, path: String, message: String)
    case failed(sessionID: UUID?, message: String)
}
