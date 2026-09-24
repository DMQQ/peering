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
/// No path: it is the one the listing was asked for plus this name, so sending it per entry would
/// be the same string a thousand times. See ``TerminalRequest/listDirectory(sessionID:path:)``.
public struct RemoteDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    /// Whether the entry opens as a folder. True for a symbolic link that points at one, because
    /// that is the question a tap on the row is asking; ``isSymlink`` is what tells the two apart.
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// The entry's own size, which is what `ls -l` prints beside it: the bytes a file holds, or for
    /// a directory the bytes its own entry takes. Zero where the provider could not say, which is
    /// the one listing that answers with names alone. See ``permissions``.
    public let size: Int64
    /// The mode bits in the form `ls -l` prints them, type character included: `-rw-r--r--`.
    /// One string rather than nine booleans in the wire format, and empty where the provider could
    /// not say, which is what lets a client tell "no size" from "zero bytes".
    public let permissions: String
    /// When the Mac says it was last changed, and nothing when the filesystem would not say.
    /// Optional rather than a stand-in date, since a row reading "1 January 1" is worse than none.
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
    /// Whether this entry is a file with the execute bit set, which is the only thing about a
    /// listing that says "this could be run". Read out of the mode string, where empty means nobody
    /// could say and is therefore "no".
    ///
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

/// What a creation should make.
///
/// Two cases and not ``RemoteFileKind``: that type answers "what are these bytes and how should
/// they be drawn", which is a question about a preview and has no answer for a folder.
public enum RemoteEntryKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

/// A change to the shape of a folder: something made, something renamed, something gone.
///
/// One type rather than four request cases, because the four share every part of their handling: a
/// definite path, a wait, one outcome and a re-list of the folder afterwards. It is also the unit
/// the safety rules are written against, ``RemoteFileName/isValid(_:)`` being asked by whoever
/// builds one of these and by whoever answers it.
public enum RemoteFileOperation: Codable, Equatable, Sendable {
    /// Make an empty file, or a folder. `path` is where it should end up, already joined.
    ///
    /// A file arrives empty and is not written here, so "make a file" and "start typing in it" are
    /// two taps rather than one dialog.
    case create(path: String, kind: RemoteEntryKind)
    /// Give something a new name, in the folder it is already in.
    ///
    /// A name, not a path: a rename that took a path could cross folders, which is a different
    /// feature. The two ends both hold ``RemoteFileName/isValid(_:)``, which refuses a slash.
    case rename(path: String, to: String)
    /// Remove something, and everything inside it if it is a folder.
    ///
    /// Recursive, and the recursion is the caller's decision: what arrives here has already been
    /// through a confirmation, and the host cannot ask again with nobody at its screen.
    case delete(path: String)
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
    /// One folder's contents, for the file browser. `nil` means the Mac's home folder, the one path
    /// the phone cannot work out for itself; the answer carries the path it resolved to.
    case listDirectory(sessionID: UUID, path: String?)
    /// A file's contents, for the browser's preview. Read-only, and bounded: see
    /// ``TerminalEvent/fileContents(sessionID:path:offset:totalBytes:data:isLast:)``.
    case readFile(sessionID: UUID, path: String)
    /// Opening a file for writing, which replaces whatever was there. It carries no contents, which
    /// is what makes a save and an upload the same mechanism.
    ///
    /// The size is declared up front, so a Mac that will not take a file that large can say so
    /// cheaply, and the file is not replaced until ``writeChunk(sessionID:path:data:isLast:)`` says
    /// the last piece arrived.
    case beginWrite(sessionID: UUID, path: String, totalBytes: Int)
    /// A piece of a file being written.
    ///
    /// Chunked because the control channel caps a message at ``ProtocolInfo/maxControlPayload`` and
    /// a file is not a message. Pieces arrive in order, so the host appends rather than seeks, and
    /// the one marked last commits the file.
    case writeChunk(sessionID: UUID, path: String, data: Data, isLast: Bool)
    /// Something made, renamed or removed, for the file browser.
    ///
    /// One request rather than one per operation (see ``RemoteFileOperation``), answered by
    /// ``TerminalEvent/fileOperationDone(sessionID:path:note:)`` or
    /// ``TerminalEvent/fileOperationFailure(sessionID:path:message:)``.
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
    case created(TerminalSessionInfo)
    /// The terminal's name changed, by a command run in it or by the user typing one.
    case renamed(TerminalSessionInfo)
    case output(sessionID: UUID, data: Data)
    case attention(sessionID: UUID, kind: TerminalAttentionKind, message: String)
    /// A command that ran long enough to be worth mentioning has returned control to the prompt.
    /// Unlike ``attention``, nothing is being waited on: this is a fire-and-forget notice, not a
    /// state a terminal sits in. `command` is nil when the shell's hook could not name what ran.
    case commandFinished(sessionID: UUID, command: String?, duration: TimeInterval, exitStatus: Int32)
    case exited(sessionID: UUID, status: Int32)
    case closed(sessionID: UUID)
    /// One folder's contents, sorted by the host (folders first, then names) so every client shows
    /// the same order without agreeing on how to compare strings. `truncated` says the host's entry
    /// cap was reached and there is more on disk than was sent.
    case directory(sessionID: UUID, path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    /// A file being previewed, in pieces.
    ///
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
    /// A browse request that could not be answered: a folder that could not be read, or a file that
    /// could not be shown. Carries the path it was about, so the panel that asked can clear the
    /// right waiting state.
    ///
    /// Not ``failed``, which lands on the terminal's tab instead.
    case browseFailure(sessionID: UUID, path: String, message: String)
    /// A file the client wrote is now on disk, at the size it ended up.
    ///
    /// The size is what the Mac counted rather than what the client sent, so the two agreeing is the
    /// client's evidence that all of it arrived. What is on disk is a question the client asks with
    /// ``TerminalRequest/readFile(sessionID:path:)``.
    case wroteFile(sessionID: UUID, path: String, totalBytes: Int)
    /// A write that did not happen.
    ///
    /// Not ``browseFailure``, which is a file that could not be read and clears the panel; the right
    /// answer to a failed save is to leave the editor open on the text the user still has.
    case writeFailure(sessionID: UUID, path: String, message: String)
    /// Something was made, renamed or removed, and it happened.
    ///
    /// `path` is the path the client sent, echoed back rather than reconstructed, because a client
    /// holding a path it built cannot recognise an answer spelled differently. For a rename that is
    /// the old path.
    ///
    /// `note` is a finished sentence written by the machine that did the work, and it is what goes
    /// in the terminal's log.
    case fileOperationDone(sessionID: UUID, path: String, note: String)
    /// A change that did not happen.
    ///
    /// Its own event rather than a share of ``browseFailure``: that one says a folder could not be
    /// read, and this one is about a folder read perfectly well and then not changed. A failed read
    /// replaces the list; a failed rename leaves the list up and puts a sentence beside it.
    case fileOperationFailure(sessionID: UUID, path: String, message: String)
    case failed(sessionID: UUID?, message: String)
}
