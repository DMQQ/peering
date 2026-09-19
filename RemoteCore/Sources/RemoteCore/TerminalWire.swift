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

extension RemoteDirectoryEntry {
    /// Whether this entry is a file with the execute bit set, which is the only thing about a
    /// listing that says "this could be run".
    ///
    /// Read out of the mode string rather than asked for separately, because the mode string is
    /// already the answer and ``permissions`` is empty exactly when nobody could say — the `ls`
    /// fallback that produces names and nothing else. Empty is therefore "no", which is the honest
    /// answer to a question whose evidence is missing.
    ///
    /// **Only a regular file counts.** A symbolic link's own mode carries the execute bit whether
    /// or not the thing it points at does — `lrwxr-xr-x` is what `ls` prints for a link to a text
    /// file — so a link is left out rather than offered as a run button that fails. Following one
    /// is a question for whoever owns the filesystem, and the listing has not asked it.
    public var isExecutable: Bool {
        let bits = Array(permissions)
        // Ten characters: the type, then owner, group and others, three each. Execute is the third
        // of each group, at 3, 6 and 9.
        guard bits.count == 10, bits[0] == "-" else { return false }
        // `x` is the ordinary spelling. `s` and `t` are setuid, setgid and sticky shown *in place
        // of* it, and those appear only where the execute bit is set as well — their uppercase
        // forms mark the same bits without execute, which is the whole distinction `ls` is drawing.
        func isExecuteMark(_ character: Character) -> Bool {
            character == "x" || character == "s" || character == "t"
        }
        return isExecuteMark(bits[3]) || isExecuteMark(bits[6]) || isExecuteMark(bits[9])
    }
}

/// What a creation should make.
///
/// Two cases and not ``RemoteFileKind``, deliberately. That type answers "what are these bytes
/// and how should they be drawn" — text, a picture, an SVG — which is a question about a preview
/// and has no answer for a folder. Borrowing it here would mean a folder is a `.image` or a
/// `.svg`, and the code would read as though somebody had chosen between those two.
public enum RemoteEntryKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

/// A change to the shape of a folder: something made, something renamed, something gone.
///
/// One type rather than four request cases, because the four share every part of their handling —
/// a definite path, a wait, one outcome, and a re-list of the folder afterwards. The alternative
/// was four cases whose bodies were the same six lines with a different Foundation call in the
/// middle, and a client with four waiting flags where one will do.
///
/// It is also the unit the safety rules are written against. ``RemoteFileName/isValid(_:)``
/// describes what a name may be, and it is asked by whoever builds one of these *and* by whoever
/// answers it, because the two ends are on opposite sides of a network.
public enum RemoteFileOperation: Codable, Equatable, Sendable {
    /// Make an empty file, or a folder. `path` is where it should end up, already joined.
    ///
    /// A file arrives empty and is not written here: an empty file is one the browser can open,
    /// preview and edit, so "make a file" and "start typing in it" are two taps rather than one
    /// dialog that has to guess how much text to carry.
    case create(path: String, kind: RemoteEntryKind)
    /// Give something a new name, in the folder it is already in.
    ///
    /// A *name*, not a path — that distinction is the whole of why this is not a `move`. A rename
    /// that took a path could cross folders, which is a different feature with different
    /// questions, and the one thing a browser row can honestly offer is a new name for the thing
    /// on it. The two ends both hold ``RemoteFileName/isValid(_:)``, which refuses a slash.
    case rename(path: String, to: String)
    /// Remove something, and everything inside it if it is a folder.
    ///
    /// Recursive, and the recursion is the caller's decision to make rather than the host's: what
    /// arrives here has already been through a confirmation that said what it would do. The host
    /// does not ask again — it cannot, there is nobody at its screen — and it does not second
    /// guess, because a browser that offers to delete a folder and then refuses one that is not
    /// empty is a browser whose Delete button means two different things.
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
    /// Something made, renamed or removed, for the file browser.
    ///
    /// One request rather than one per operation — see ``RemoteFileOperation`` — and answered in
    /// one piece rather than in chunks, because none of these carries a file. The answers are
    /// ``TerminalEvent/fileOperationDone(sessionID:path:note:)`` and
    /// ``TerminalEvent/fileOperationFailure(sessionID:path:message:)``.
    case changeFile(sessionID: UUID, operation: RemoteFileOperation)
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
    ///
    /// `kind` is what the pieces are, and it rides on every one of them rather than only the
    /// first: the client's buffer is not a preview until it knows whether it is holding text it
    /// should decode or a picture it should hand to `UIImage`, and the answer has to be there
    /// before the first chunk is drawn. It is the same value every time, which is the price of a
    /// reader that can start on any piece.
    case fileContents(
        sessionID: UUID,
        path: String,
        kind: RemoteFileKind,
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
    /// Something was made, renamed or removed, and it happened.
    ///
    /// `path` is the path the *client sent*, echoed back rather than reconstructed, which is the
    /// same rule ``wroteFile`` follows and for the same reason: a client holding a path it built
    /// cannot recognise an answer that comes back spelled differently. For a rename that path is
    /// the old one, because that is the row the client was looking at.
    ///
    /// `note` is a finished sentence, written by the machine that did the work. It is the side
    /// that knows what actually happened — a recursive delete is the clearest case, since only the
    /// host counted what was inside the folder — and it is the same arrangement
    /// ``browseFailure`` already has, where the far end composes the prose and the phone shows it.
    /// The sentence is what goes in the terminal's log, so a rename that quietly worked still
    /// leaves a line behind saying it did.
    case fileOperationDone(sessionID: UUID, path: String, note: String)
    /// A change that did not happen.
    ///
    /// Its own event rather than a share of ``browseFailure``, for the reason ``writeFailure``
    /// gives: that one says a folder could not be read, and this one is about a folder that was
    /// read perfectly well and then not changed. The difference is what the panel does with it —
    /// a failed read replaces the list, and a failed rename leaves the list up and puts a sentence
    /// beside it.
    case fileOperationFailure(sessionID: UUID, path: String, message: String)
    case failed(sessionID: UUID?, message: String)
}
