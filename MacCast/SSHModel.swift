import Foundation
import Observation
import RemoteCore
import SSHCore
import os

private let sshModelLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// How much of a shell's output is kept.
///
/// Bounded for the same reason the Mac's own terminals are: a command like `yes`, or `cat` on a
/// large file, otherwise grows a buffer until the app is killed — and it is killed while the user
/// is watching a session they cannot get back. Oldest-first, so what survives is the end of the
/// output, which is where the prompt and the last error are.
///
/// A quarter of what ``RemoteTerminal`` keeps, and deliberately. That terminal renders by walking
/// its whole buffer on every arriving chunk, which is fine at a prompt and is not fine for
/// `tail -f` over a slow link; this is the compromise until the renderer is incremental.
private let scrollbackLimit = 128 * 1024

/// One open shell, as the screen sees it.
///
/// A class rather than a struct in an array, because output arrives many times a second and
/// mutating a struct held in an array invalidates every row of the list that reads the array.
@Observable
@MainActor
final class SSHTerminal: Identifiable {
    enum Phase: Equatable {
        case connecting
        case live
        /// Ended, with the reason if there is one to show.
        case ended(String?)
    }

    let id = UUID()
    let host: SSHHost
    let session: SSHSession

    /// When the shell was asked for, so the connection log can say how long it was up.
    let startedAt: Date

    /// Whether this shell has already been written to the log.
    ///
    /// Kept on the shell rather than in a set of ids on the model, and the reason is the second
    /// close that never comes: a session that fails and *then* closes emits both, and the second
    /// one has to be a no-op. A set would answer that too, right up until it had to be pruned
    /// against the list of open shells to stop it growing — where this goes away with the object
    /// the record is about, and a shell is exactly one record by construction.
    @ObservationIgnored fileprivate var isRecorded = false

    /// The password this shell was opened with, so a second shell on the same machine does not
    /// ask for it again.
    ///
    /// In memory, and only for as long as the shell is. The keychain is where a password is
    /// *kept*; this is not keeping one, it is remembering what was just typed — and it is marked
    /// unobserved because nothing on screen reads it, so a change to it should never redraw.
    @ObservationIgnored let password: String

    private(set) var phase: Phase = .connecting
    /// Raw bytes, not a string.
    ///
    /// A shell's output carries escape sequences and partial UTF-8 characters, and the app already
    /// has the renderer that copes with both — ``TerminalTextSanitizer``. Decoding here would mean
    /// either showing raw control codes or writing a second sanitizer that drifts from the first.
    private(set) var output = Data()

    /// The name the tab shows.
    var title: String { host.displayName }

    /// Whether ending this shell would lose anything.
    ///
    /// The question the Mac's own terminals ask before they close, and the same answer: a
    /// connection that failed has nothing behind it, so dismissing it is not worth a dialog —
    /// and everything else does. A live shell most of all, because ending it stops whatever is
    /// running on the far end, and that is not a thing to do on a mis-tap of a small cross
    /// sitting next to a tab's name.
    var hasSomethingToLose: Bool {
        if case .ended = phase { return false }
        return true
    }

    init(host: SSHHost, session: SSHSession, password: String, startedAt: Date = Date()) {
        self.host = host
        self.session = session
        self.password = password
        self.startedAt = startedAt
    }

    /// The grid the shell is drawn against. Kept in step with what the server was told, so the
    /// screen the user sees is the screen the program on the far end drew for.
    var columns = 80
    var rows = 24

    /// The output, ready to draw.
    ///
    /// Run through ``TerminalScreen`` rather than ``TerminalTextSanitizer/renderLines(_:)``, and
    /// that is the whole of the difference between a shell and a *screen*. A line-based renderer
    /// throws cursor addressing away, so a program that draws by positioning — `htop`, `top`,
    /// `vim`, `less` — collapses into a linear replay of every frame it ever painted. The emulator
    /// applies those sequences to a grid, so what comes out is the last frame, in place.
    var styled: [TerminalStyledLine] {
        var screen = TerminalScreen(columns: columns, rows: rows)
        screen.feed(output)
        return screen.styled
    }

    fileprivate func append(_ chunk: Data) {
        output.append(chunk)
        if output.count > scrollbackLimit {
            output.removeFirst(output.count - scrollbackLimit)
        }
    }

    fileprivate func setPhase(_ phase: Phase) {
        self.phase = phase
    }
}

/// A host key the user is being asked about, and what to do about the answer.
struct SSHKeyPrompt: Identifiable {
    let id = UUID()
    let prompt: SSHHostKeyPrompt
}

/// The SSH tab's state.
///
/// Owned by the screen rather than by the app, unlike ``SessionModel``: an SSH connection is not
/// the app's reason to exist, it does not need to survive the screen being left, and keeping it
/// here means leaving the tab hangs up — which is what closing a terminal window does.
@Observable
@MainActor
final class SSHModel {
    /// The list as the screen shows it — most recently connected first.
    private(set) var hosts: [SSHHost] = []
    /// The same hosts in the order the user made, which is what gets written back.
    ///
    /// Two arrays rather than one, because `ordered(_:)` sorts on read on purpose: storing the
    /// sorted list would mean a connection reordering what is on disk, and the stored order is
    /// the one fact a later sort cannot recover.
    private var saved: [SSHHost] = []

    private(set) var terminals: [SSHTerminal] = []
    var selectedTerminalID: UUID?

    /// A first-sight host key waiting on an answer, and the continuation that carries it.
    private(set) var keyPrompt: SSHKeyPrompt?
    private var keyAnswer: CheckedContinuation<Bool, Never>?

    /// The shell the terminal screen is showing, or nil while the list is up.
    var selectedTerminal: SSHTerminal? {
        guard let id = selectedTerminalID else { return nil }
        return terminals.first { $0.id == id }
    }

    /// The shells that are still worth going back to.
    ///
    /// A session that ended is not one — whether it failed or the server hung up. There is no
    /// session behind it, only a message, and a row offering to "open" it again leads to the same
    /// failure. It stays on screen while the user is looking at it, because the message is the
    /// point of it, and it goes when they leave.
    var openShells: [SSHTerminal] {
        terminals.filter { terminal in
            if case .ended = terminal.phase { return false }
            return true
        }
    }

    /// Leaves the terminal screen for the list, dropping anything that has already finished.
    ///
    /// The selection always clears. It used to be guarded on the selected shell having been among
    /// the ones just dropped — which for a *live* shell is never, so the button removed nothing
    /// and cleared nothing and the screen simply sat there. Leaving is what this does; whether
    /// anything was dropped on the way out is a separate question with a separate answer.
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

    private func isLive(_ terminal: SSHTerminal) -> Bool {
        if case .ended = terminal.phase { return false }
        return true
    }

    /// What has finished lately, newest first. The Servers tab draws the top of it.
    ///
    /// A shell that is still open is not in here: the "Open" card above the list is where a live
    /// session lives, and the same connection appearing in two lists is the sort of thing that
    /// makes a user wonder which one is real.
    private(set) var history: [SSHConnectionRecord] = []

    private let store = SSHHostStore()
    private let knownHosts = SSHKnownHosts()
    private let credentials = SSHCredentialStore()
    private let passcodes = SSHPasscodeStore()
    private let historyStore = SSHConnectionHistoryStore()

    init() {
        saved = store.load()
        hosts = SSHHostStore.ordered(saved)
        history = historyStore.load()
        mirrorServers()
    }

    /// Copies the list somewhere Siri can read it.
    ///
    /// The app's own defaults are not visible to an entity query running without it, so the
    /// servers are mirrored into the App Group beside `knownMacs` — see ``SharedStore``. Written
    /// whenever the list changes, because a server missing from here is a server Siri claims not
    /// to know about, and "I could not find that" is a worse answer than any error.
    private func mirrorServers() {
        SharedStore.knownServers = hosts.map {
            SharedStore.KnownServer(id: $0.id.uuidString, name: $0.displayName, detail: $0.detail)
        }
    }

    // MARK: - Quick commands

    /// Types a saved command into the shell and runs it.
    ///
    /// The *list* lives in ``QuickCommands``, which both terminals read — this is only the part
    /// that is specific to an SSH session.
    ///
    /// Sent as the command and then a carriage return, exactly as typing it would be — deliberately
    /// not a separate "execute this" path, because a shell has no such thing. What arrives is what
    /// the user would have typed, which also means the shell's own history keeps it.
    func run(_ command: SSHQuickCommand, on terminal: SSHTerminal) {
        send(Data(command.command.utf8), to: terminal)
        send(Data("\r".utf8), to: terminal)
    }

    // MARK: - The list

    func save(_ host: SSHHost) {
        saved.removeAll { $0.id == host.id }
        saved.append(host)
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()

        // A server that no longer asks for a passcode must not keep one. Left behind, it would be
        // waiting for the *next* passcode the user sets here — which is one they have long since
        // forgotten, and the first thing they would be asked for is a number they never chose.
        if host.lock != .passcode, passcodes.hasPasscode(for: host.id) {
            passcodes.remove(for: host.id)
        }
    }

    func delete(_ host: SSHHost) {
        saved.removeAll { $0.id == host.id }
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()
        // The credential, the pinned key and the passcode go with it. Leaving them behind would
        // mean a host re-added later silently reusing a password the user thought they had deleted
        // — and, for the passcode, a lock that opens for a number nobody set on this server.
        credentials.remove(for: host.id)
        passcodes.remove(for: host.id)
    }

    /// Whether a password is already stored, so the connect flow knows to ask.
    func hasStoredPassword(for host: SSHHost) -> Bool {
        credentials.hasCredential(for: host.id)
    }

    /// The stored password, or nil when there is none.
    ///
    /// v1 only stores passwords — ``SSHCredential`` is an enum precisely so that adding keys later
    /// is a case and a line rather than a migration, and this is the one place that will have to
    /// grow when it does.
    func storedPassword(for host: SSHHost) -> String? {
        guard case .password(let value) = credentials.credential(for: host.id) else { return nil }
        return value
    }

    func store(password: String, for host: SSHHost, remember: Bool) {
        guard remember else { return }
        credentials.save(.password(password), for: host.id)
    }

    /// Forgets a server's pinned key, so the next connection asks about it as a first sight.
    ///
    /// The only route past a changed key — see ``SSHSessionError/hostKeyChanged(known:presented:)``.
    func forgetKey(for host: SSHHost) {
        knownHosts.forget(host.endpoint)
    }

    func isKeyKnown(for host: SSHHost) -> Bool {
        knownHosts.host(for: host.endpoint) != nil
    }

    // MARK: - A server's own lock

    /// The server a locked connection is waiting on, or nil while none is.
    ///
    /// Held here rather than in the Servers screen, for the reason ``wantsFocus`` is: the request
    /// can come from a Shortcut or from Siri before that screen has ever been built, and a
    /// question with nowhere to be asked would either be dropped or hang the request forever.
    var lockedHost: SSHHost?

    /// Whether the last passcode typed at a lock was the wrong one, so the sheet can say so.
    ///
    /// One flag for the whole app rather than a count per server: there is one lock sheet and it
    /// is showing one server, and a dictionary would be a way for two answers to disagree.
    private(set) var lockRejected = false

    func hasPasscode(for host: SSHHost) -> Bool {
        passcodes.hasPasscode(for: host.id)
    }

    /// Saves a server as the editor left it, passcode and all.
    ///
    /// One method rather than a `save` and a `setPasscode` the caller has to remember to pair up,
    /// because the two halves have to agree: a server left marked as passcode-locked with nothing
    /// stored behind it is a server with no way in at all.
    func save(_ host: SSHHost, passcode: String?) {
        var accepted = host
        if host.lock == .passcode {
            if let passcode {
                // The Keychain refused the write. Falling back to unlocked is the lesser harm and
                // it is not silent — the row loses its badge on the way back, so what is on screen
                // is what is actually true.
                if !passcodes.set(passcode, for: host.id) { accepted.lock = .off }
            } else if !passcodes.hasPasscode(for: host.id) {
                accepted.lock = .off
            }
        }
        save(accepted)
    }

    /// Opens a server, asking first for whatever it is locked behind.
    ///
    /// **The one door.** The row, the log and a Shortcut all arrive here, because a gate hung on
    /// the row's tap is a gate every other entrance walks straight past — the same reasoning the
    /// app-wide lock is built on. The deliberate exception is a *second* shell on a machine that
    /// already has one: the user is looking at that session, so the lock has been answered, and
    /// asking again would make the second tab cost more than the first without protecting anything.
    func requestOpen(_ host: SSHHost) {
        // Everything this can lead to — a shell, a lock sheet, a password prompt — is drawn by the
        // Servers screen, and this is reachable from the Sessions tab since the log moved there.
        // Asking for the tab is the same thing ``openShellFromIntent(_:)`` does with it, and for
        // the same reason: without it, a row in that log is a tap that appears to do nothing.
        wantsFocus = true

        if let existing = openShells.first(where: { $0.host.id == host.id }) {
            selectedTerminalID = existing.id
            return
        }

        guard host.lock.isLocked else {
            connect(host)
            return
        }

        lockRejected = false
        lockedHost = host
    }

    /// Asks the device to say who is holding it: Face ID, Touch ID, or its passcode.
    ///
    /// A refusal leaves the sheet exactly as it was. Cancelling the system prompt is not a failed
    /// attempt at anything — it is the user changing their mind — and a sheet that reported it as
    /// an error would put "that was wrong" under a box nobody had filled in yet.
    func unlockWithDevice(_ host: SSHHost) async {
        guard await DeviceAuthentication.unlock(reason: "Open a shell on \(host.displayName).") else { return }
        acceptUnlock(of: host)
    }

    func submit(passcode: String, for host: SSHHost) {
        guard SSHPasscodeStore.isValid(passcode) else { return }
        guard passcodes.verify(passcode, for: host.id) else {
            lockRejected = true
            return
        }
        acceptUnlock(of: host)
    }

    func cancelUnlock() {
        lockedHost = nil
        lockRejected = false
    }

    private func acceptUnlock(of host: SSHHost) {
        lockedHost = nil
        lockRejected = false
        connect(host)
    }

    // MARK: - The connection log

    /// Writes one line into the log, once.
    ///
    /// A session that fails and *then* closes emits both events, and the first is the one worth
    /// keeping: "the server's key has changed" is the fact, and "the connection ended" is that same
    /// failure said again in less useful words.
    private func record(_ terminal: SSHTerminal, outcome: SSHConnectionRecord.Outcome) {
        guard !terminal.isRecorded else { return }
        terminal.isRecorded = true

        history.insert(
            SSHConnectionRecord(
                hostID: terminal.host.id,
                name: terminal.host.displayName,
                detail: terminal.host.detail,
                startedAt: terminal.startedAt,
                endedAt: Date(),
                outcome: outcome
            ),
            at: 0
        )
        if history.count > SSHConnectionHistoryStore.limit {
            history.removeLast(history.count - SSHConnectionHistoryStore.limit)
        }
        historyStore.save(history)
    }

    // MARK: - Connecting

    /// Opens a shell. Returns once the connection is *starting*; the tab reports the rest.
    @discardableResult
    func open(_ host: SSHHost, password: String, remember: Bool) -> SSHTerminal {
        if remember {
            credentials.save(.password(password), for: host.id)
        }

        let session = SSHSession(host: host, password: password, knownHosts: knownHosts) { [weak self] prompt in
            await self?.ask(about: prompt) ?? false
        }

        let terminal = SSHTerminal(host: host, session: session, password: password)
        terminals.append(terminal)
        selectedTerminalID = terminal.id

        // The row is stamped only once a shell actually opened. Doing it here would record an
        // attempt, and the list is meant to say what worked.
        Task { @MainActor [weak self] in
            for await event in session.events {
                switch event {
                case .connected:
                    terminal.setPhase(.live)
                    self?.markConnected(host)
                case .output(let data):
                    terminal.append(data)
                case .failed(let error):
                    let reason = Self.describe(error)
                    terminal.setPhase(.ended(reason))
                    self?.clearPendingBrowsing(for: terminal.id)
                    self?.record(terminal, outcome: .failed(reason))
                case .closed:
                    if case .ended = terminal.phase {} else { terminal.setPhase(.ended(nil)) }
                    self?.clearPendingBrowsing(for: terminal.id)
                    // `.closed` arrives whether the shell was live or had already failed, which is
                    // what lets one case cover both the user closing a session and the server
                    // hanging up on it. A failed attempt never gets here as `.connected`, because
                    // ``record(_:outcome:)`` keeps the first answer and the failure came first.
                    self?.record(terminal, outcome: .connected)
                }
            }
        }

        session.connect()
        return terminal
    }

    /// Opens a shell on a server that is already past whatever lock it carries.
    ///
    /// Asks for the password only when there is not one stored, which is what the row's tap used
    /// to do in the screen. Moved here because the row is no longer the only caller: the lock sheet
    /// and the connection log both arrive at it too, and a password prompt is the same question
    /// whichever of the three asked for the shell.
    func connect(_ host: SSHHost) {
        if let password = storedPassword(for: host) {
            open(host, password: password, remember: false)
        } else {
            pendingPasswordHost = host
        }
    }

    /// A shell whose end has been asked for and not yet confirmed.
    ///
    /// Held on the model rather than in either screen, because the cross that asks for it lives
    /// in two places — the tab strip and the "Open" card — and those are two different screens.
    /// Two copies of the pending state would be two dialogs that could disagree.
    var pendingClose: SSHTerminal?

    /// Asks to end a shell, with a question when there is something to lose.
    func requestClose(_ terminal: SSHTerminal) {
        if terminal.hasSomethingToLose {
            pendingClose = terminal
        } else {
            close(terminal)
        }
    }

    func close(_ terminal: SSHTerminal) {
        terminal.session.close()
        forgetBrowsing(for: terminal.id)
        terminals.removeAll { $0.id == terminal.id }
        if selectedTerminalID == terminal.id {
            selectedTerminalID = terminals.last?.id
        }
    }

    func send(_ data: Data, to terminal: SSHTerminal) {
        terminal.session.send(data)
    }

    /// Tells the shell how wide the screen is, in character cells.
    ///
    /// Both ends: the server, so the program on it lays out for the right number of columns, and
    /// the local emulator, so the grid it renders into is the same shape. Letting those two drift
    /// would put the text in the wrong place even when the program on the far end was drawing it
    /// perfectly.
    func resize(columns: Int, rows: Int, for terminal: SSHTerminal) {
        terminal.columns = columns
        terminal.rows = rows
        terminal.session.resize(columns: columns, rows: rows)
    }

    private func markConnected(_ host: SSHHost) {
        var updated = host
        updated.lastConnectedAt = Date()
        save(updated)
    }

    // MARK: - Browsing

    /// The folder each shell's browser is showing, and `nil` while that is still wherever the
    /// server starts a session with its path not yet resolved.
    ///
    /// On the model rather than in the screen, for the reason the Mac's is: the screen is rebuilt
    /// every time the tab is opened, and the folder a server is being browsed at is not something
    /// that should be forgotten in between.
    private(set) var browsingPaths: [UUID: String] = [:]

    /// What the server sent for a folder, and the three things that can be true of a request for
    /// one: still waiting, answered, or refused.
    ///
    /// Keyed the way the Mac's are, with one of its keys — see ``RemoteDirectoryKey``, which is
    /// a terminal on this phone and a path at the other end of it whether that end is a Mac or a
    /// server.
    private(set) var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]
    private(set) var pendingDirectories: Set<RemoteDirectoryKey> = []
    private(set) var browseFailures: [RemoteDirectoryKey: String] = [:]

    /// The file the browser is showing, and `nil` while it is showing a folder.
    private(set) var filePreview: RemoteFilePreview?

    /// How large a file this app will try to send. See ``uploadFile(_:sessionID:)``.
    ///
    /// Sixty-four megabytes, which is a number about this phone rather than about any server: the
    /// bytes are read into memory to be sent, and the alternative to refusing is being killed by the
    /// system partway through, which looks to the user like the app crashing for no reason.
    static let maximumUploadBytes = 64 * 1_048_576

    /// Whether a save or an upload is in flight, and the last thing that went wrong with one.
    ///
    /// One pair of flags for both, because they are the same operation from the screen's point of
    /// view — something is being written to the server and the user should not be told nothing while
    /// it is. The failures are kept apart, because the two are fixed differently: a save that failed
    /// is a file to correct, an upload that failed is a file to choose again.
    private(set) var isSavingFile = false
    private(set) var saveFailure: String?
    private(set) var isUploadingFile = false
    private(set) var uploadFailure: String?

    func browsingPath(for id: UUID) -> String? { browsingPaths[id] }

    /// Points a shell's browser at a folder, before asking for it.
    func setBrowsingPath(_ path: String?, for id: UUID) { browsingPaths[id] = path }

    /// Asks the server for a folder's contents.
    ///
    /// `nil` is wherever the server starts a session, which is where a browser opens: the shell's
    /// own working directory is not something this side is told, and a login's home is the one
    /// answer that is right often enough. The answer names the folder it resolved to, and every
    /// request after the first is built from that.
    func listDirectory(_ path: String?, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)

        Task { @MainActor in
            // "." rather than a home this end guessed at: "wherever you start" is a question only
            // the server can answer, and it answers it with the path in the result.
            let outcome: Result<SSHDirectory, any Error>
            do { outcome = .success(try await terminal.session.listDirectory(at: path ?? ".")) }
            catch { outcome = .failure(error) }

            // A shell closed while this was in the air takes its answer with it. Both halves of
            // that matter: a listing kept for a terminal nothing can select again is a dictionary
            // entry with no way back, and its failure line would be worse — the key is this
            // shell's own identity, so the entry would outlive the shell by the life of the tab.
            guard terminals.contains(where: { $0.id == id }) else { return }

            switch outcome {
            case .success(let listing):
                directories[RemoteDirectoryKey(terminalID: id, path: listing.path)] = RemoteDirectory(
                    entries: listing.entries,
                    isTruncated: listing.isTruncated
                )
                pendingDirectories.remove(key)
                browseFailures.removeValue(forKey: key)
                // The one answer that can move a browser: a request that named no folder is
                // answered with the one it resolved to, and that is what the breadcrumbs and
                // every later request are built from.
                if browsingPaths[id] == nil { browsingPaths[id] = listing.path }
            case .failure(let error):
                pendingDirectories.remove(key)
                browseFailures[key] = Self.browseMessage(error)
            }
        }
    }

    /// Asks the server to read a file, replacing whatever was being previewed.
    func previewFile(_ path: String, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        // Put up first and filled in when the read lands, which is how the Mac's browser does it:
        // the panel already knows how to draw a file that is still coming, and a second state for
        // "asked for and not yet answered" would be a second thing to keep in step.
        filePreview = RemoteFilePreview(terminalID: id, path: path)

        Task { @MainActor in
            // The guard before each write, rather than a helper: an answer about a file nobody is
            // looking at any more is dropped rather than shown under the wrong name — the preview
            // closed, or another file opened since.
            do {
                let contents = try await terminal.session.readFile(at: path)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: contents.path,
                    totalBytes: contents.totalBytes,
                    data: contents.data,
                    isComplete: true,
                    // The reader's answer, not this side's guess. See the note on the field: the
                    // two disagree in exactly the case that matters, where the file is longer than
                    // the cap and the server never said how long it was.
                    reportedTruncation: contents.isTruncated
                )
            } catch {
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                // The same dictionary a refused folder goes in, and that is not a shortcut: the
                // panel asks for a failure by path, and a file has a path too. It is also the
                // only reason the preview panel needs nothing added to it.
                browseFailures[RemoteDirectoryKey(terminalID: id, path: path)] = Self.browseMessage(error)
            }
        }
    }

    func closePreview() {
        filePreview = nil
    }

    /// Writes what the editor holds back to the server, replacing the file.
    ///
    /// **Refuses a file whose read was cut short, and that refusal is the method rather than a
    /// nicety.** A write replaces the file — SFTP has no "change these bytes" — so saving a preview
    /// of the first 128 KB of something longer would destroy the rest and leave nothing behind to
    /// say it had happened. The panel does not offer to edit such a file, and this does not extend
    /// that offer any trust: the guard is here because this is the last place it can be.
    func saveFile(_ text: String, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let preview = filePreview,
              preview.terminalID == id,
              !preview.isTruncated
        else { return }

        let path = preview.path
        isSavingFile = true
        saveFailure = nil

        Task { @MainActor in
            defer { isSavingFile = false }
            do {
                let written = try await terminal.session.writeFile(Data(text.utf8), to: path)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                // Replaced with what the server now holds rather than with what was sent. They are
                // the same bytes unless something went wrong between here and the disk, and the
                // whole reason the write answers with contents is so that "unless" has somewhere to
                // show up.
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: written.path,
                    totalBytes: written.totalBytes,
                    data: written.data,
                    isComplete: true,
                    reportedTruncation: written.isTruncated
                )
            } catch {
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                saveFailure = Self.browseMessage(error)
            }
        }
    }

    /// Copies a file the user picked into the folder being browsed.
    ///
    /// The destination is the folder on screen and the name is the one the file arrived with, which
    /// is the only naming rule that needs no explanation. An existing file is replaced, because
    /// that is what an upload to a folder you are looking at means — and the alternative, a silent
    /// rename, leaves two files where the user expects one.
    ///
    /// **Capped, and the cap is about this phone rather than the server.** The bytes are read into
    /// memory to be sent, so an upload of something enormous is an app the system kills rather than
    /// a transfer that is slow. Refused with a sentence, which is a thing the user can act on.
    func uploadFile(_ url: URL, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let folder = browsingPaths[id]
        else { return }

        let name = url.lastPathComponent
        let destination = folder.hasSuffix("/") ? folder + name : folder + "/" + name

        isUploadingFile = true
        uploadFailure = nil

        Task { @MainActor in
            defer { isUploadingFile = false }

            // Security-scoped, because a file from the picker is outside the app's sandbox and
            // reading it without this is a permission failure that looks like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let read: Result<Data, any Error>
            do {
                // Off the main actor: this is a file the user chose from anywhere on the device,
                // and reading a few tens of megabytes of it on the main actor is a hitch on a screen
                // that is drawing a terminal.
                let bytes = try await Task.detached { try Data(contentsOf: url) }.value
                read = bytes.count > Self.maximumUploadBytes
                    ? .failure(SSHSessionError.browse(
                        "That file is too large to send from this phone (the limit is \(Self.maximumUploadBytes / 1_048_576) MB)."
                    ))
                    : .success(bytes)
            } catch {
                read = .failure(error)
            }

            switch read {
            case .failure(let error):
                uploadFailure = Self.browseMessage(error)
            case .success(let data):
                do {
                    _ = try await terminal.session.writeFile(data, to: destination)
                    // The folder on screen is now out of date by exactly one file, and asking again
                    // is cheaper to get right than patching one entry in.
                    listDirectory(folder, sessionID: id)
                } catch {
                    uploadFailure = Self.browseMessage(error)
                }
            }
        }
    }

    func directory(_ path: String?, sessionID id: UUID) -> RemoteDirectory? {
        directories[RemoteDirectoryKey(terminalID: id, path: path)]
    }

    func isLoadingDirectory(_ path: String?, sessionID id: UUID) -> Bool {
        pendingDirectories.contains(RemoteDirectoryKey(terminalID: id, path: path))
    }

    func browseFailure(_ path: String?, sessionID id: UUID) -> String? {
        browseFailures[RemoteDirectoryKey(terminalID: id, path: path)]
    }

    /// Stops waiting on anything this shell was asked for.
    ///
    /// For the requests that are never answered at all: a session that failed or hung up has no
    /// loop left to answer one, and a panel left waiting on a listing that is never coming has no
    /// way back on its own.
    private func clearPendingBrowsing(for id: UUID) {
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
    }

    /// Everything remembered about a shell's browsing, dropped with the shell it belongs to.
    private func forgetBrowsing(for id: UUID) {
        directories = directories.filter { $0.key.terminalID != id }
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
        browseFailures = browseFailures.filter { $0.key.terminalID != id }
        browsingPaths.removeValue(forKey: id)
        if filePreview?.terminalID == id { filePreview = nil }
    }

    /// The sentence under a browse that did not work.
    ///
    /// The session has already said it in the terms the panel shows — a folder that is not there,
    /// a file that is not text, a server with no SFTP — so this passes it through rather than
    /// inventing a second wording for it. What is left is the case where there is no answer
    /// because there is no session: a request made as the connection went.
    private static func browseMessage(_ error: any Error) -> String {
        guard let error = error as? SSHSessionError else { return error.localizedDescription }
        switch error {
        case .browse(let reason): return reason
        case .notConnected: return "The connection ended before the server answered."
        default: return describe(error)
        }
    }

    // MARK: - What Siri asks for

    /// Raised by an intent that wants the Servers tab, and cleared by the screen that shows it.
    ///
    /// The app's navigation lives in ``HostPickerView``, which an intent has no way to reach. So
    /// the intent raises a flag and the router — which is already watching this model — does the
    /// switching. An intent that tried to push a view itself would be reaching across an isolation
    /// boundary to touch something it does not own.
    var wantsFocus = false

    /// The host an intent wanted and could not sign in to, so a screen can ask.
    var pendingPasswordHost: SSHHost?

    /// Opens a shell because something other than a tap asked for one.
    ///
    /// Three answers rather than one, because an intent cannot ask a question and a password is
    /// the one thing it might need that is not in the request. With a shell already open it goes
    /// there; with a stored password it connects; with neither it hands the user to the screen
    /// that *can* ask — which is the only honest thing a voice command can do about a secret.
    func openShellFromIntent(_ host: SSHHost) {
        // The list rather than whichever shell was last being looked at. An intent asked for *this*
        // server, and everything below either lands on its shell or puts a question on screen — and
        // a question asked over somebody else's terminal is a question about the wrong machine.
        selectedTerminalID = nil
        // Which asks for the tab itself. The lock is asked for here like anywhere else: a Shortcut
        // is a way in, not a way past.
        requestOpen(host)
    }

    /// Opens another shell on a machine that already has one.
    ///
    /// The password comes from the shell that is open rather than from the keychain, because the
    /// common case is a user who did *not* ask to have it remembered: they are looking at a
    /// working session and want a second one, and being asked to type it again would make the
    /// second tab cost more than the first. Nothing is stored anywhere — this is the one that was
    /// just typed, still in memory because its session is.
    @discardableResult
    func openAnotherShell(on terminal: SSHTerminal) -> SSHTerminal {
        // Deliberately not through ``requestOpen(_:)``, and so deliberately not past a lock either
        // — see there. This is the second shell on a machine the user is already looking at.
        open(terminal.host, password: terminal.password, remember: false)
    }

    /// Ends every shell. For the intent, which has no way to say *which* one.
    func closeAllShells() {
        for terminal in terminals {
            terminal.session.close()
        }
        terminals.removeAll()
        selectedTerminalID = nil
    }

    // MARK: - The first-sight question

    /// Suspends the handshake until the user answers.
    ///
    /// Called from the transport, so it hops to the main actor to put a sheet up and then waits.
    /// The `Task` is what makes the hop legal from a non-isolated `@Sendable` closure.
    private func ask(about prompt: SSHHostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.keyAnswer = continuation
                self.keyPrompt = SSHKeyPrompt(prompt: prompt)
            }
        }
    }

    func answerKeyPrompt(_ accepted: Bool) {
        keyPrompt = nil
        keyAnswer?.resume(returning: accepted)
        keyAnswer = nil
    }

    /// The sentence under a failed connection.
    private static func describe(_ error: SSHSessionError) -> String {
        switch error {
        case .hostKeyRejected:
            return "You did not accept this server's key."
        case .hostKeyChanged:
            return "The server's key has changed since you last connected. If this was not you, do not continue."
        case .transport(let reason):
            return reason
        case .notConnected:
            return "The connection ended."
        // A browse that failed is not a connection that failed, and it is reported where it
        // happened rather than on the shell's own line: see ``browseMessage(_:)``.
        case .browse(let reason):
            return reason
        }
    }
}
