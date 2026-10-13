import Foundation
import PeeringKit
import Observation
import RemoteCore
import SSHCore

/// Owned by the screen, not the app: leaving the tab hangs up, like closing a terminal window.
@Observable
@MainActor
final class SSHModel {
    var hosts: [SSHHost] = []
    /// Two arrays because `ordered(_:)` sorts on read: storing the sorted list would let a connection reorder what is on disk, which a later sort cannot recover.
    var saved: [SSHHost] = []

    var terminals: [SSHTerminal] = []
    var selectedTerminalID: UUID?

    /// The prompt on screen, always the head of ``keyQueue``.
    var keyPrompt: SSHKeyPrompt?
    /// `nonisolated(unsafe)` so `deinit` can resume what is left; every other access is on the main actor.
    @ObservationIgnored nonisolated(unsafe) var keyQueue = PromptQueue<PendingKeyPrompt>()

    var selectedTerminal: SSHTerminal? {
        guard let id = selectedTerminalID else { return nil }
        return terminals.first { $0.id == id }
    }

    /// A session that ended is not worth going back to: a row offering to open it leads to the same failure. It stays while the user looks at it, since the message is the point.
    var openShells: [SSHTerminal] {
        terminals.filter { terminal in
            if case .ended = terminal.phase { return false }
            return true
        }
    }

    /// The selection always clears: it used to be guarded on the selected shell being among those dropped, which for a live shell is never, so the button did nothing.
    func leaveTerminal() {
        for terminal in terminals where !isLive(terminal) {
            forgetBrowsing(for: terminal.id)
        }
        terminals.removeAll { terminal in
            if case .ended = terminal.phase { return true }
            return false
        }
        selectedTerminalID = nil
    }

    func isLive(_ terminal: SSHTerminal) -> Bool {
        if case .ended = terminal.phase { return false }
        return true
    }

    /// A live shell is not in here: the "Open" card holds it, and one connection in two lists makes a user wonder which is real.
    var history: [SSHConnectionRecord] = []

    let store = SSHHostStore()
    let knownHosts = SSHKnownHosts()
    let credentials = SSHCredentialStore()
    let passcodes = SSHPasscodeStore()
    let historyStore = SSHConnectionHistoryStore()

    deinit {
        for pending in keyQueue.removeAll() { pending.continuation.resume(returning: false) }
    }

    init() {
        saved = store.load()
        hosts = SSHHostStore.ordered(saved)
        history = historyStore.load()
        mirrorServers()
    }

    /// An entity query running without the app cannot see its defaults, so servers are mirrored into the App Group beside `knownMacs` (``SharedStore``), written on every change.
    func mirrorServers() {
        SharedStore.knownServers = hosts.map {
            SharedStore.KnownServer(id: $0.id.uuidString, name: $0.displayName, detail: $0.detail)
        }
    }



    // MARK: - A server's own lock

    /// Held here, not in the Servers screen: a Shortcut or Siri request can arrive before that screen exists, and a question with nowhere to be asked would drop or hang.
    var lockedHost: SSHHost?

    /// One flag for the app: there is one lock sheet showing one server, and a dictionary lets two answers disagree.
    var lockRejected = false


    // MARK: - Connecting

    /// Held on the model: the cross lives in the tab strip and the "Open" card, two screens, and two copies would be two dialogs that could disagree.
    var pendingClose: SSHTerminal?

    // MARK: - Port forwards

    /// Keyed by host, not a shell: a forward on 8080 is carried once, and two shells each binding it would fail with "address already in use" for a user who only opened a second tab.
    var forwardStates: [UUID: [UUID: SSHForwardState]] = [:]

    /// Not observable: its only news is in `forwardStates`.
    @ObservationIgnored var forwarders: [UUID: SSHForwarder] = [:]
    /// The dialer needs a session now, not the one that existed when the forwarder was made, and this lookup avoids retaining a connection the user may have closed.
    @ObservationIgnored var hostSessions: [UUID: [SSHSession]] = [:]

    // MARK: - Browsing

    /// On the model because the screen is rebuilt each time the tab opens.
    var browsingPaths: [UUID: String] = [:]

    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]
    var pendingDirectories: Set<RemoteDirectoryKey> = []
    var browseFailures: [RemoteDirectoryKey: String] = [:]

    var filePreview: RemoteFilePreview?

    /// Sixty-four megabytes, a number about this phone: the file is read into memory to send, and the alternative to refusing is the system killing the app.
    /// This browser streams nothing, unlike the Mac's: the whole file is held up to this figure. Streaming needs an SFTP write that takes pieces (a new command in `SSHCore`). The size is asked of the filesystem before the file is read.
    static let maximumUploadBytes = 64 * 1_048_576

    /// One pair of flags for save and upload, the same operation to the screen; failures are kept apart since a save failure is a file to correct and an upload failure a file to choose again.
    var isSavingFile = false
    var saveFailure: String?
    var isUploadingFile = false
    var uploadFailure: String?

    // MARK: - Changing the tree

    /// Singular where the Mac's are keyed by terminal: this browser draws one shell at a time.
    var isChangingFile = false
    var changeFailure: String?

    // MARK: - What Siri asks for

    /// The app's navigation lives in ``HostPickerView``, which an intent cannot reach, so it raises a flag and the router switches.
    var wantsFocus = false

    var pendingPasswordHost: SSHHost?


}
