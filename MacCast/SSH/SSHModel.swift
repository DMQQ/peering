import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

/// Bounded like the Mac's terminals: `yes` or `cat` on a large file would otherwise grow a buffer until the app is killed mid-session. Oldest-first, so the end (prompt and last error) survives.
/// A quarter of what ``RemoteTerminal`` keeps: that terminal renders by walking its whole buffer per chunk, too slow for `tail -f` over a slow link, until the renderer is incremental.
private let scrollbackLimit = 128 * 1024

/// How far past it the buffer may run before the tail is rebuilt, so trims are batched.
private let scrollbackSlack = 32 * 1024

/// A class, not a struct in an array: output arrives many times a second and mutating a struct invalidates every row.
@Observable
@MainActor
final class SSHTerminal: Identifiable {
    enum Phase: Equatable {
        case connecting
        case live
        case ended(String?)
    }

    let id = UUID()
    let host: SSHHost
    let session: SSHSession

    let startedAt: Date

    /// Kept on the shell, not a set of ids: a session that fails and then closes emits both, and the second must be a no-op; a set would need pruning, where this goes with the object.
    @ObservationIgnored fileprivate var isRecorded = false

    /// In memory only, for the shell's lifetime: it remembers what was just typed or chosen rather than keeping a credential, and is unobserved because nothing on screen reads it.
    @ObservationIgnored let credential: SSHCredential
    @ObservationIgnored private var attentionDetector = TerminalAttentionDetector()

    private(set) var phase: Phase = .connecting
    /// A shell's output has escape sequences and partial UTF-8, which ``TerminalTextSanitizer`` already copes with; decoding here would mean raw control codes or a second sanitizer that drifts.
    private(set) var output = Data()

    var title: String { host.displayName }

    /// Same answer as the Mac's terminals: a failed connection has nothing behind it, and a live shell most of all, since ending it stops whatever runs on the far end.
    var hasSomethingToLose: Bool {
        if case .ended = phase { return false }
        return true
    }

    init(
        host: SSHHost,
        session: SSHSession,
        credential: SSHCredential,
        startedAt: Date = Date()
    ) {
        self.host = host
        self.session = session
        self.credential = credential
        self.startedAt = startedAt
    }

    /// Kept in step with what the server was told.
    var columns = 80
    var rows = 24

    /// Run through ``TerminalScreen`` rather than a line renderer: that throws cursor addressing away, so `htop`, `vim` and `less` collapse into a replay of every frame they painted.
    /// Kept rather than rebuilt: building from the whole session per render is valid only while the grid holds still. It is fed what is new and resized in place (see ``TerminalScreenFeed``).
    private let screenFeed = TerminalScreenFeed()

    var styled: [TerminalStyledLine] {
        screenFeed.screen(for: output, columns: columns, rows: rows).styled
    }

    fileprivate func append(_ chunk: Data) -> TerminalAttentionKind? {
        output.append(chunk)
        // Rebound rather than cut with `removeFirst`, which moves `Data`'s start index and keeps the whole session alive.
        if output.count > scrollbackLimit + scrollbackSlack {
            let dropped = output.count - scrollbackLimit
            output = Data(output.dropFirst(dropped))
            // The screen remembers how much of this buffer it applied, so it must be told those bytes are gone.
            screenFeed.discardFront(dropped)
        }
        return attentionDetector.receive(chunk)
    }

    fileprivate func userDidRespond() {
        attentionDetector.userDidRespond()
    }

    fileprivate func setPhase(_ phase: Phase) {
        self.phase = phase
    }
}

struct SSHKeyPrompt: Identifiable {
    let id = UUID()
    let prompt: SSHHostKeyPrompt
}

/// Owned by the screen, not the app: leaving the tab hangs up, like closing a terminal window.
@Observable
@MainActor
final class SSHModel {
    private(set) var hosts: [SSHHost] = []
    /// Two arrays because `ordered(_:)` sorts on read: storing the sorted list would let a connection reorder what is on disk, which a later sort cannot recover.
    private var saved: [SSHHost] = []

    private(set) var terminals: [SSHTerminal] = []
    var selectedTerminalID: UUID?

    private(set) var keyPrompt: SSHKeyPrompt?
    private var keyAnswer: CheckedContinuation<Bool, Never>?

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

    private func isLive(_ terminal: SSHTerminal) -> Bool {
        if case .ended = terminal.phase { return false }
        return true
    }

    /// A live shell is not in here: the "Open" card holds it, and one connection in two lists makes a user wonder which is real.
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

    /// An entity query running without the app cannot see its defaults, so servers are mirrored into the App Group beside `knownMacs` (``SharedStore``), written on every change.
    private func mirrorServers() {
        SharedStore.knownServers = hosts.map {
            SharedStore.KnownServer(id: $0.id.uuidString, name: $0.displayName, detail: $0.detail)
        }
    }

    // MARK: - Quick commands

    /// The list lives in ``QuickCommands``.
    /// Sent as the command then a carriage return, as typing would be: a shell has no "execute" path, and its history keeps it.
    func run(_ command: SSHQuickCommand, on terminal: SSHTerminal) {
        send(Data(command.command.utf8), to: terminal)
        send(Data("\r".utf8), to: terminal)
    }

    // MARK: - The list

    func save(_ host: SSHHost) {
        Analytics.featureUsed(.sshHostSaved)
        saved.removeAll { $0.id == host.id }
        saved.append(host)
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()

        // A server that no longer asks for a passcode must not keep one: it would wait for the next passcode the user sets here.
        if host.lock != .passcode, passcodes.hasPasscode(for: host.id) {
            passcodes.remove(for: host.id)
        }
    }

    func delete(_ host: SSHHost) {
        Analytics.featureUsed(.sshHostDeleted)
        saved.removeAll { $0.id == host.id }
        store.save(saved)
        hosts = SSHHostStore.ordered(saved)
        mirrorServers()
        // The credential, pinned key and passcode go with it: otherwise a re-added host silently reuses a deleted password, and a passcode lock opens for a number nobody set on this server.
        credentials.remove(for: host.id)
        passcodes.remove(for: host.id)
    }

    /// Asks about a credential, not a password: a host that logs in with a key must not be sent to a password sheet.
    func hasStoredCredential(for host: SSHHost) -> Bool {
        credentials.hasCredential(for: host.id)
    }

    /// Returns the whole credential, not a password: unwrapping to a string would put the enum back in every caller's hands.
    func storedCredential(for host: SSHHost) -> SSHCredential? {
        credentials.credential(for: host.id)
    }

    func credentialKind(for host: SSHHost) -> String? {
        switch storedCredential(for: host) {
        case .password: return String(localized: "Password saved")
        case .key: return String(localized: "Key saved")
        case nil: return nil
        }
    }

    func store(password: String, for host: SSHHost, remember: Bool) {
        guard remember else { return }
        credentials.save(.password(password), for: host.id)
    }

    /// `.unchanged` must not write: a keychain write on every edit can land on top of a key something else changed. This is the only place that acts on ``SSHSecretChange``.
    func apply(_ change: SSHSecretChange, to host: SSHHost, rememberPassword: Bool) {
        switch change {
        case .unchanged:
            break
        case .use(.password(let password)):
            store(password: password, for: host, remember: rememberPassword)
        case .use(.key(let key)):
            store(key: key, for: host)
        case .forget:
            forgetCredential(for: host)
        }
    }

    /// Replacing, not coexisting, is why ``SSHCredential`` is an enum: a host given a key must not still hold its password.
    @discardableResult
    func store(key: SSHKeyPair, for host: SSHHost) -> Bool {
        credentials.save(.key(key), for: host.id)
    }

    @discardableResult
    func forgetCredential(for host: SSHHost) -> Bool {
        credentials.remove(for: host.id)
    }

    /// Forgets a pinned key so the next connection asks as a first sight; the only route past a changed key (``SSHSessionError/hostKeyChanged(known:presented:)``).
    func forgetKey(for host: SSHHost) {
        knownHosts.forget(host.endpoint)
    }

    func isKeyKnown(for host: SSHHost) -> Bool {
        knownHosts.host(for: host.endpoint) != nil
    }

    // MARK: - A server's own lock

    /// Held here, not in the Servers screen: a Shortcut or Siri request can arrive before that screen exists, and a question with nowhere to be asked would drop or hang.
    var lockedHost: SSHHost?

    /// One flag for the app: there is one lock sheet showing one server, and a dictionary lets two answers disagree.
    private(set) var lockRejected = false

    func hasPasscode(for host: SSHHost) -> Bool {
        passcodes.hasPasscode(for: host.id)
    }

    /// One method, not a `save` plus a `setPasscode`: a server marked passcode-locked with nothing stored behind it has no way in.
    func save(_ host: SSHHost, passcode: String?) {
        Analytics.featureUsed(.sshHostSaved)
        var accepted = host
        if host.lock == .passcode {
            if let passcode {
                // The Keychain refused the write: falling back to unlocked is the lesser harm and not silent, as the row loses its badge.
                if !passcodes.set(passcode, for: host.id) { accepted.lock = .off }
            } else if !passcodes.hasPasscode(for: host.id) {
                accepted.lock = .off
            }
        }
        save(accepted)
    }

    /// The one door: the row, the log and a Shortcut all arrive here, since a gate on the row's tap is walked past by every other entrance. A second shell on a machine with one is exempt: the lock was already answered.
    func requestOpen(_ host: SSHHost) {
        // Reachable from the Sessions tab, while a shell, lock sheet or password prompt is drawn by the Servers screen; asking for the tab (as `openShellFromIntent(_:)` does) stops a log row seeming to do nothing.
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

    /// Cancelling the system prompt is the user changing their mind, not a failed attempt, so the sheet is left exactly as it was.
    func unlockWithDevice(_ host: SSHHost) async {
        Analytics.featureUsed(.sshUnlocked)
        guard await DeviceAuthentication.unlock(reason: String(localized: "Open a shell on \(host.displayName).")) else { return }
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

    /// A session that fails then closes emits both events, and the first is the fact worth keeping.
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

    @discardableResult
    func open(_ host: SSHHost, credential: SSHCredential, remember: Bool) -> SSHTerminal {
        Analytics.featureUsed(.sshConnected)
        SessionNotifier.shared.prepareForFirstConnect()
        if remember {
            credentials.save(credential, for: host.id)
        }

        let session = SSHSession(host: host, credential: credential, knownHosts: knownHosts) { [weak self] prompt in
            await self?.ask(about: prompt) ?? false
        }

        let terminal = SSHTerminal(host: host, session: session, credential: credential)
        terminals.append(terminal)
        selectedTerminalID = terminal.id
        hostSessions[host.id, default: []].append(session)
        syncTerminalActivity()

        // Stamped only once a shell opened: the list says what worked, not what was tried.
        Task { @MainActor [weak self] in
            for await event in session.events {
                switch event {
                case .connected:
                    terminal.setPhase(.live)
                    self?.markConnected(host)
                    self?.syncTerminalActivity()
                    // After `.live` and in its own task, so the shell is usable the moment it opens rather than once every listener has bound.
                    if let self {
                        Task { await self.startEnabledForwards(on: host) }
                    }
                case .output(let data):
                    if let attention = terminal.append(data) {
                        let reason = attention == .password ? String(localized: "a password") : String(localized: "your response")
                        SessionNotifier.shared.terminalNeedsAttention(
                            String(localized: "SSH “\(terminal.title)” is waiting for \(reason)."),
                            sessionID: terminal.id,
                            name: terminal.title,
                            isSSH: true
                        )
                    }
                case .failed(let error):
                    let reason = Self.describe(error)
                    terminal.setPhase(.ended(reason))
                    self?.clearPendingBrowsing(for: terminal.id)
                    self?.record(terminal, outcome: .failed(reason))
                    self?.syncTerminalActivity()
                    await self?.endForwards(for: terminal)
                case .closed:
                    if case .ended = terminal.phase {} else { terminal.setPhase(.ended(nil)) }
                    self?.clearPendingBrowsing(for: terminal.id)
                    self?.syncTerminalActivity()
                    await self?.endForwards(for: terminal)
                    // `.closed` arrives whether the shell was live or failed, so one case covers the user closing and the server hanging up. A failed attempt never reports `.connected`, as `record(_:outcome:)` keeps the first answer.
                    self?.record(terminal, outcome: .connected)
                }
            }
        }

        session.connect()
        return terminal
    }

    /// Asks for the password only when none is stored; the lock sheet and the connection log arrive here too.
    func connect(_ host: SSHHost) {
        if let credential = storedCredential(for: host) {
            open(host, credential: credential, remember: false)
        } else {
            pendingPasswordHost = host
        }
    }

    /// Held on the model: the cross lives in the tab strip and the "Open" card, two screens, and two copies would be two dialogs that could disagree.
    var pendingClose: SSHTerminal?

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
        syncTerminalActivity()
        // Ended here as well as on `.closed`: a listener that outlived its shell is a port open with nothing behind it, so connections through it hang.
        Task { await self.endForwards(for: terminal) }
    }

    /// Two shells on one server share one set of forwards, so stopping them whenever any shell ended would let the second tab kill the first's tunnels.
    private func endForwards(for terminal: SSHTerminal) async {
        let hostID = terminal.host.id
        hostSessions[hostID]?.removeAll { $0 === terminal.session }
        let stillOpen = hostSessions[hostID]?.contains { session in
            terminals.contains { $0.session === session }
        } ?? false
        guard !stillOpen else { return }

        await stopForwards(on: hostID)
        hostSessions.removeValue(forKey: hostID)
    }

    func send(_ data: Data, to terminal: SSHTerminal) {
        terminal.userDidRespond()
        terminal.session.send(data)
    }

    /// Both ends: the server, so the program lays out for the right columns, and the local emulator, so the grid has the same shape.
    func resize(columns: Int, rows: Int, for terminal: SSHTerminal) {
        guard columns != terminal.columns || rows != terminal.rows else { return }
        terminal.columns = columns
        terminal.rows = rows
        terminal.session.resize(columns: columns, rows: rows)
    }

    private func markConnected(_ host: SSHHost) {
        var updated = host
        updated.lastConnectedAt = Date()
        save(updated)
    }

    // MARK: - Port forwards

    /// Keyed by host, not a shell: a forward on 8080 is carried once, and two shells each binding it would fail with "address already in use" for a user who only opened a second tab.
    private(set) var forwardStates: [UUID: [UUID: SSHForwardState]] = [:]

    /// Not observable: its only news is in `forwardStates`.
    @ObservationIgnored private var forwarders: [UUID: SSHForwarder] = [:]
    /// The dialer needs a session now, not the one that existed when the forwarder was made, and this lookup avoids retaining a connection the user may have closed.
    @ObservationIgnored private var hostSessions: [UUID: [SSHSession]] = [:]

    func forwardState(_ forward: SSHPortForward, on host: SSHHost) -> SSHForwardState {
        forwardStates[host.id]?[forward.id] ?? .stopped
    }

    func hasRunningForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { $0.isRunning }) ?? false
    }

    func hasBrokenForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { state in
            if case .failed = state { return true }
            return false
        }) ?? false
    }

    /// The dialer resolves the session when called, so one forwarder outlives the shell that started it: a second shell picks up the same listening sockets. Holding the session directly would pin the first shell open as long as its forwards run.
    private func forwarder(for host: SSHHost) -> SSHForwarder {
        if let existing = forwarders[host.id] { return existing }

        let id = host.id
        let forwarder = SSHForwarder { [weak self] remoteHost, remotePort, localPort in
            guard let session = await self?.currentSession(for: id) else {
                throw SSHSessionError.notConnected
            }
            return try await session.openDirectChannel(to: remoteHost, port: remotePort, from: localPort)
        }

        forwarders[host.id] = forwarder
        // States are pushed, not polled: a server-side refusal happens whenever another app takes the port, never at a moment this screen caused.
        Task { @MainActor [weak self] in
            for await states in forwarder.changes {
                self?.forwardStates[id] = states
            }
        }
        return forwarder
    }

    @MainActor
    private func currentSession(for hostID: UUID) -> SSHSession? {
        hostSessions[hostID]?.first { session in
            terminals.contains { $0.session === session && isLive($0) }
        }
    }

    /// Automatic, as in OpenSSH's config: writing the forward down on the server is the intent. Not silent: a failed forward lands in `forwardStates` and the toolbar button says so.
    func startEnabledForwards(on host: SSHHost) async {
        let forwarder = forwarder(for: host)
        for forward in host.forwards where forward.isEnabled {
            // A forward already listening is left alone: this runs per shell that opens, and a second shell must not rebuild the first's tunnels.
            guard await forwarder.state(of: forward.id) == .stopped else { continue }
            try? await forwarder.start(forward)
        }
    }

    func start(_ forward: SSHPortForward, on host: SSHHost) async {
        // The throw is dropped: a failed bind is already in the forward's own state with the same sentence.
        try? await forwarder(for: host).start(forward)
    }

    func stop(_ forward: SSHPortForward, on host: SSHHost) async {
        await forwarder(for: host).stop(forward.id)
    }

    private func stopForwards(on hostID: UUID) async {
        await forwarders[hostID]?.stopAll()
    }

    // MARK: - Browsing

    /// On the model because the screen is rebuilt each time the tab opens.
    private(set) var browsingPaths: [UUID: String] = [:]

    private(set) var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]
    private(set) var pendingDirectories: Set<RemoteDirectoryKey> = []
    private(set) var browseFailures: [RemoteDirectoryKey: String] = [:]

    private(set) var filePreview: RemoteFilePreview?

    /// Sixty-four megabytes, a number about this phone: the file is read into memory to send, and the alternative to refusing is the system killing the app.
    /// This browser streams nothing, unlike the Mac's: the whole file is held up to this figure. Streaming needs an SFTP write that takes pieces (a new command in `SSHCore`). The size is asked of the filesystem before the file is read.
    static let maximumUploadBytes = 64 * 1_048_576

    /// One pair of flags for save and upload, the same operation to the screen; failures are kept apart since a save failure is a file to correct and an upload failure a file to choose again.
    private(set) var isSavingFile = false
    private(set) var saveFailure: String?
    private(set) var isUploadingFile = false
    private(set) var uploadFailure: String?

    func browsingPath(for id: UUID) -> String? { browsingPaths[id] }

    func setBrowsingPath(_ path: String?, for id: UUID) { browsingPaths[id] = path }

    /// `nil` is wherever the server starts a session: the shell's working directory is not told to this side, and the answer names the folder it resolved to, from which later requests are built.
    func listDirectory(_ path: String?, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)

        Task { @MainActor in
            // "." rather than a guessed home: only the server can answer "wherever you start".
            let outcome: Result<SSHDirectory, any Error>
            do { outcome = .success(try await terminal.session.listDirectory(at: path ?? ".")) }
            catch { outcome = .failure(error) }

            // A shell closed mid-flight takes its answer with it: a listing kept for an unselectable terminal is an entry with no way back, and the key is the shell's identity.
            guard terminals.contains(where: { $0.id == id }) else { return }

            switch outcome {
            case .success(let listing):
                directories[RemoteDirectoryKey(terminalID: id, path: listing.path)] = RemoteDirectory(
                    entries: listing.entries,
                    isTruncated: listing.isTruncated
                )
                pendingDirectories.remove(key)
                browseFailures.removeValue(forKey: key)
                // The one answer that can move a browser: a request that named no folder is answered with the one it resolved to.
                if browsingPaths[id] == nil { browsingPaths[id] = listing.path }
            case .failure(let error):
                pendingDirectories.remove(key)
                browseFailures[key] = Self.browseMessage(error)
            }
        }
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        // Put up first and filled in when the read lands, as the Mac's browser does: a second state for "asked, not answered" would need keeping in step.
        filePreview = RemoteFilePreview(terminalID: id, path: path)

        Task { @MainActor in
            // The guard before each write: an answer about a file nobody is looking at any more is dropped rather than shown under the wrong name.
            do {
                let contents = try await terminal.session.readFile(at: path)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: contents.path,
                    // The server's own answer about what it read, as the Mac's browser gets; nothing re-derives it from the name.
                    kind: contents.kind,
                    totalBytes: contents.totalBytes,
                    data: contents.data,
                    isComplete: true,
                    // The reader's answer, not this side's guess: they disagree when the file is longer than the cap and the server never said how long it was.
                    reportedTruncation: contents.isTruncated
                )
            } catch {
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                // The same dictionary a refused folder goes in: the panel asks for a failure by path, so the preview panel needs nothing added.
                browseFailures[RemoteDirectoryKey(terminalID: id, path: path)] = Self.browseMessage(error)
            }
        }
    }

    func closePreview() {
        filePreview = nil
    }

    /// Refuses a file whose read was cut short: a write replaces the file (SFTP has no partial write), so saving a 128 KB preview of something longer destroys the rest. The panel does not offer to edit such a file; this guard is the last place to stop it.
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
                // Replaced with what the server now holds, not what was sent: they differ only if something went wrong, and the write answers with contents so that has somewhere to show.
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: written.path,
                    kind: written.kind,
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

    /// The destination is the folder on screen with the file's own name; an existing file is replaced, as a silent rename leaves two files where one is expected.
    /// Capped because of this phone: an enormous upload is an app the system kills, so it is refused with a sentence the user can act on.
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

            // Security-scoped: a picker file is outside the sandbox and reading it without this fails like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let read: Result<Data, any Error>
            do {
                // The size first, and this order is the fix: it used to be checked after the read, so an over-limit file was read into memory to learn it was too big.
                let size = try await Task.detached {
                    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }.value
                guard size <= Self.maximumUploadBytes else {
                    throw SSHSessionError.browse(
                        String(localized: "That file is too large to send from this device (the limit is \(Self.maximumUploadBytes / 1_048_576) MB).")
                    )
                }
                // Off the main actor: reading tens of megabytes on it is a hitch on a screen drawing a terminal.
                read = .success(try await Task.detached { try Data(contentsOf: url) }.value)
            } catch {
                read = .failure(error)
            }

            switch read {
            case .failure(let error):
                uploadFailure = Self.browseMessage(error)
            case .success(let data):
                do {
                    _ = try await terminal.session.writeFile(data, to: destination)
                    // The folder on screen is out of date by one file, and asking again is cheaper than patching an entry.
                    listDirectory(folder, sessionID: id)
                } catch {
                    uploadFailure = Self.browseMessage(error)
                }
            }
        }
    }

    // MARK: - Changing the tree

    /// Singular where the Mac's are keyed by terminal: this browser draws one shell at a time.
    private(set) var isChangingFile = false
    private(set) var changeFailure: String?

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        change(.create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// The path is rebuilt from the folder and the new name, not sent as a destination: a path could name somewhere else.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name), name != entry.name else { return }
        change(.rename(path: childPath(entry.name, of: folder), to: name), sessionID: id)
    }

    /// The confirmation is the panel's, where both browsers go through; nothing here can ask, being a `Task` with no view.
    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        change(.delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

    /// Refused while one is in the air: they share one flag, and the second answer would clear a wait the first owns.
    /// Re-asked on success and failure: nothing here can tell what the filesystem looks like after a half-failed delete.
    private func change(_ operation: RemoteFileOperation, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let folder = browsingPaths[id],
              !isChangingFile
        else { return }

        isChangingFile = true
        changeFailure = nil

        Task { @MainActor in
            defer { isChangingFile = false }
            do {
                _ = try await terminal.session.change(operation)
            } catch {
                // The shell has gone, so nobody is left to tell or re-list.
                guard terminals.contains(where: { $0.id == id }) else { return }
                changeFailure = Self.browseMessage(error)
            }
            listDirectory(folder, sessionID: id)
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

    /// For requests never answered: a session that failed or hung up has no loop left to answer, and a waiting panel has no way back.
    private func clearPendingBrowsing(for id: UUID) {
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
    }

    private func forgetBrowsing(for id: UUID) {
        directories = directories.filter { $0.key.terminalID != id }
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
        browseFailures = browseFailures.filter { $0.key.terminalID != id }
        browsingPaths.removeValue(forKey: id)
        if filePreview?.terminalID == id { filePreview = nil }
        // A change in the air through a gone shell cannot finish, and `isChangingFile` disables the panel's controls: left set, the browser returns with a dead New Folder button.
        isChangingFile = false
        changeFailure = nil
    }

    /// The session already words it as the panel shows; this passes it through. What is left is no session: a request made as the connection went.
    private static func browseMessage(_ error: any Error) -> String {
        guard let error = error as? SSHSessionError else { return error.localizedDescription }
        switch error {
        case .browse(let reason): return reason
        case .notConnected: return String(localized: "The connection ended before the server answered.")
        default: return describe(error)
        }
    }

    // MARK: - What Siri asks for

    /// The app's navigation lives in ``HostPickerView``, which an intent cannot reach, so it raises a flag and the router switches.
    var wantsFocus = false

    var pendingPasswordHost: SSHHost?

    /// Three answers because an intent cannot ask a question: with a shell open it goes there, with a stored credential it connects, with neither it hands the user to the screen that can ask. A stored key counts, so a shortcut to a key-only server does not open a password sheet.
    func openShellFromIntent(_ host: SSHHost) {
        // The list, not the last shell looked at: a question asked over somebody else's terminal is about the wrong machine.
        selectedTerminalID = nil
        // The lock is asked for here like anywhere: a Shortcut is a way in, not a way past.
        requestOpen(host)
    }

    /// The credential comes from the open shell, not the keychain: the user may not have asked to remember it, and asking again would make the second tab cost more. Nothing is stored.
    @discardableResult
    func openAnotherShell(on terminal: SSHTerminal) -> SSHTerminal {
        // Deliberately not through `requestOpen(_:)` and so not past a lock: this is the second shell on a machine already in view.
        open(terminal.host, credential: terminal.credential, remember: false)
    }

    /// The representative name comes from the most recently opened live shell, so a second server does not rename the card away from the one in view.
    private func syncTerminalActivity() {
        let live = openShells
        guard !live.isEmpty else {
            TerminalActivity.shared.end()
            return
        }
        let name = live.last!.host.displayName
        let startedAt = live.compactMap { t -> Date? in
            if case .live = t.phase { return t.startedAt } else { return nil }
        }.min()
        TerminalActivity.shared.update(serverName: name, startedAt: startedAt, shellCount: live.count)
    }

    func closeAllShells() {
        for terminal in terminals {
            terminal.session.close()
        }
        terminals.removeAll()
        selectedTerminalID = nil
        TerminalActivity.shared.end()
        // Every host: the loop above dropped every shell at once, so there is no "last one" per machine.
        let hosts = forwarders.keys
        Task { @MainActor in
            for host in hosts { await self.stopForwards(on: host) }
        }
        hostSessions.removeAll()
    }

    // MARK: - The first-sight question

    /// Called from the transport, so it hops to the main actor to show a sheet and waits; the `Task` makes the hop legal from a non-isolated `@Sendable` closure.
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

    private static func describe(_ error: SSHSessionError) -> String {
        switch error {
        case .hostKeyRejected:
            return String(localized: "You did not accept this server's key.")
        case .hostKeyChanged:
            return String(localized: "The server's key has changed since you last connected. If this was not you, do not continue.")
        case .transport(let reason):
            return reason
        case .notConnected:
            return String(localized: "The connection ended.")
        // A browse that failed is reported where it happened (see `browseMessage(_:)`).
        case .browse(let reason):
            return reason
        // Nor is a forward that failed: its sentence belongs on the forward's row. This case only keeps the switch exhaustive as the error type grows.
        case .forward(let reason):
            return SSHForwarder.describe(reason)
        }
    }
}
