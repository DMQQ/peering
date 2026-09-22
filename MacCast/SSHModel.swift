import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

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

    /// What this shell was opened with, so a second shell on the same machine does not ask again.
    ///
    /// In memory, and only for as long as the shell is. The keychain is where a credential is
    /// *kept*; this is not keeping one, it is remembering what was just typed or just chosen — and
    /// it is marked unobserved because nothing on screen reads it, so a change to it should never
    /// redraw. A key held here is the same key the keychain holds, which is not a second copy of a
    /// secret so much as the same one read once.
    @ObservationIgnored let credential: SSHCredential
    @ObservationIgnored private var attentionDetector = TerminalAttentionDetector()

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

    fileprivate func append(_ chunk: Data) -> TerminalAttentionKind? {
        output.append(chunk)
        if output.count > scrollbackLimit {
            output.removeFirst(output.count - scrollbackLimit)
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

    /// Whether anything at all is already stored, so the connect flow knows to ask.
    ///
    /// Asks about a credential rather than about a password, which is the difference a key makes:
    /// a host that logs in with one must not be sent to a password sheet, and that would be exactly
    /// what a `hasStoredPassword` returning `false` for a key would do.
    func hasStoredCredential(for host: SSHHost) -> Bool {
        credentials.hasCredential(for: host.id)
    }

    /// What this host signs in with, or nil when nothing is stored.
    ///
    /// The one place the app reads the store, and it hands back the whole credential rather than a
    /// password: everything downstream — the session, a second shell, the row that says which kind
    /// is saved — wants "the credential", and unwrapping it here into a string would put the enum
    /// back in the caller's hands at every one of those places.
    func storedCredential(for host: SSHHost) -> SSHCredential? {
        credentials.credential(for: host.id)
    }

    /// What kind of credential this host is set up with, in the words the list uses.
    func credentialKind(for host: SSHHost) -> String? {
        switch storedCredential(for: host) {
        case .password: return "Password saved"
        case .key: return "Key saved"
        case nil: return nil
        }
    }

    func store(password: String, for host: SSHHost, remember: Bool) {
        guard remember else { return }
        credentials.save(.password(password), for: host.id)
    }

    /// Carries out what the editor decided about the secret, and nothing when it decided nothing.
    ///
    /// The three cases are three different writes, and the difference matters more than it looks:
    /// `.unchanged` must not write at all, because a keychain write on every edit is a write that
    /// can land on top of a key something else changed in the meantime. This is the only place the
    /// app acts on ``SSHSecretChange``, so it is the only place that has to get that right.
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

    /// Saves a key for this host, replacing whatever was there.
    ///
    /// Replacing rather than coexisting is the whole point of ``SSHCredential`` being an enum: a
    /// host that has just been given a key must not still be holding the password it was using,
    /// because the app would have no way to say which of the two it was about to present.
    @discardableResult
    func store(key: SSHKeyPair, for host: SSHHost) -> Bool {
        credentials.save(.key(key), for: host.id)
    }

    /// Forgets whatever this host signs in with, leaving it to ask next time.
    @discardableResult
    func forgetCredential(for host: SSHHost) -> Bool {
        credentials.remove(for: host.id)
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
    func open(_ host: SSHHost, credential: SSHCredential, remember: Bool) -> SSHTerminal {
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

        // The row is stamped only once a shell actually opened. Doing it here would record an
        // attempt, and the list is meant to say what worked.
        Task { @MainActor [weak self] in
            for await event in session.events {
                switch event {
                case .connected:
                    terminal.setPhase(.live)
                    self?.markConnected(host)
                    self?.syncTerminalActivity()
                    // After `.live` and in a task of its own, so the shell is usable the moment it
                    // opens rather than once every listener has bound.
                    if let self {
                        Task { await self.startEnabledForwards(on: host) }
                    }
                case .output(let data):
                    if let attention = terminal.append(data) {
                        let reason = attention == .password ? "a password" : "your response"
                        SessionNotifier.shared.terminalNeedsAttention(
                            "SSH “\(terminal.title)” is waiting for \(reason).",
                            sessionID: terminal.id
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
        if let credential = storedCredential(for: host) {
            open(host, credential: credential, remember: false)
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
        syncTerminalActivity()
        // Ended here as well as on the session's own `.closed`, because a listener that outlived
        // the shell it belonged to would be a port still open on the phone with nothing behind it,
        // and "nothing behind it" here means every connection through it hangs until it times out.
        Task { await self.endForwards(for: terminal) }
    }

    /// Ends a shell's forwards if it was the last shell on that machine.
    ///
    /// The "last one" test is the whole of it. Two shells on one server share one set of forwards,
    /// so a rule that stopped them whenever any shell ended would have the second tab kill the
    /// first tab's tunnels.
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

    // MARK: - Port forwards

    /// The tunnels each host is carrying, keyed by host and then by forward.
    ///
    /// Keyed by *host* rather than hung off a shell, and the two-shells case is why. A server that
    /// carries a forward on 8080 carries it once: two shells on the same machine each starting
    /// their own listener would be one bind that works and one that fails with "address already in
    /// use", shown to a user who did nothing but open a second tab. The forwards belong to the
    /// machine, and the connection that happens to be carrying them is an implementation detail the
    /// screens do not show.
    private(set) var forwardStates: [UUID: [UUID: SSHForwardState]] = [:]

    /// The live forwarder for each host, made when that host first carries anything.
    ///
    /// Not observable: nothing on screen reads the forwarder itself, and the only thing it has to
    /// say is in ``forwardStates``, which is.
    @ObservationIgnored private var forwarders: [UUID: SSHForwarder] = [:]
    /// Which sessions are open per host, so a forward's dialer can find one without holding it.
    ///
    /// The dialer needs a session *now*, not the one that happened to exist when the forwarder was
    /// made, and this is the lookup that makes that possible without the forwarder retaining a
    /// connection that the user may have closed.
    @ObservationIgnored private var hostSessions: [UUID: [SSHSession]] = [:]

    func forwardState(_ forward: SSHPortForward, on host: SSHHost) -> SSHForwardState {
        forwardStates[host.id]?[forward.id] ?? .stopped
    }

    /// Whether any of a host's forwards is up, which is what lights the port button.
    func hasRunningForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { $0.isRunning }) ?? false
    }

    /// Whether any of them is broken, so the button can say so without being opened.
    func hasBrokenForward(on host: SSHHost) -> Bool {
        (forwardStates[host.id]?.values.contains { state in
            if case .failed = state { return true }
            return false
        }) ?? false
    }

    /// The forwarder for a host, made on first use.
    ///
    /// The dialer resolves the session when it is *called* rather than when it is made, which is
    /// what lets one forwarder outlive the shell that started it: the second shell on the same
    /// machine picks up the same listening sockets and its channels go out over its own
    /// connection. Holding the session directly instead would pin the first shell open for as long
    /// as its forwards ran, which is precisely backwards.
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
        // The states are pushed rather than polled, because the thing they change for is a
        // connection the *server* refused, which happens whenever some other app on the phone
        // decides to use the port and never at a moment this screen caused.
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

    /// Starts every forward this server is set to carry.
    ///
    /// Automatic rather than a button per tunnel, and that is the decision OpenSSH's own config
    /// makes: the user wrote the forward down on the server, so opening a shell is the intent. What
    /// it is not is silent. A forward that could not open lands in ``forwardStates`` as a failure
    /// and the toolbar's button changes to say so, which is the difference between an automatic
    /// thing and a hidden one.
    func startEnabledForwards(on host: SSHHost) async {
        let forwarder = forwarder(for: host)
        for forward in host.forwards where forward.isEnabled {
            // A forward already listening is left alone. This runs once per shell that opens, and
            // the second shell on a machine must not tear down and rebuild the first one's tunnels.
            guard await forwarder.state(of: forward.id) == .stopped else { continue }
            try? await forwarder.start(forward)
        }
    }

    func start(_ forward: SSHPortForward, on host: SSHHost) async {
        // The throw is deliberately dropped: a bind that failed is already written into the
        // forward's own state with the same sentence, and a second copy travelling up through a
        // screen is a second place to keep it spelled the same.
        try? await forwarder(for: host).start(forward)
    }

    func stop(_ forward: SSHPortForward, on host: SSHHost) async {
        await forwarder(for: host).stop(forward.id)
    }

    /// Ends every tunnel on a host. What the last shell on that host closing does.
    private func stopForwards(on hostID: UUID) async {
        await forwarders[hostID]?.stopAll()
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
    ///
    /// **This browser streams nothing, and the Mac's does.** Its upload reads its file a piece at a
    /// time, so this end's cost there is one piece whatever the size; here the whole file is still
    /// held at once, up to this figure. Streaming it means an SFTP write that takes a stream of
    /// pieces rather than one `Data`, which is a new command in `SSHCore`'s command loop and a
    /// rewrite of a working write path, so what was fixed here instead is the order: the size is
    /// now asked of the filesystem *before* the file is read, where it used to be checked after,
    /// which meant a file far over the limit was read in order to discover it was over the limit.
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
                    // The server's own answer about what it just read, which is the same answer the
                    // Mac's browser gets over the wire. Nothing here re-derives it from the name.
                    kind: contents.kind,
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
                // **The size first, and this order is the fix rather than the figure.** It used to
                // be checked after the read, so a file far over the limit was read into memory in
                // order to find out that it was over the limit: the check that exists to stop the
                // app being killed by the system was itself the way it would be. Asking the
                // filesystem costs nothing and touches no bytes.
                let size = try await Task.detached {
                    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }.value
                guard size <= Self.maximumUploadBytes else {
                    throw SSHSessionError.browse(
                        "That file is too large to send from this device (the limit is \(Self.maximumUploadBytes / 1_048_576) MB)."
                    )
                }
                // Off the main actor: this is a file the user chose from anywhere on the device,
                // and reading a few tens of megabytes of it on the main actor is a hitch on a screen
                // that is drawing a terminal.
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
                    // The folder on screen is now out of date by exactly one file, and asking again
                    // is cheaper to get right than patching one entry in.
                    listDirectory(folder, sessionID: id)
                } catch {
                    uploadFailure = Self.browseMessage(error)
                }
            }
        }
    }

    // MARK: - Changing the tree

    /// What a change is waiting on, and why the last one did not happen.
    ///
    /// Singular where the Mac's are keyed by terminal, and that is the shape of the two screens
    /// rather than a shortcut: this browser draws one shell at a time and the panel that asks is
    /// the selected one, so there is no second answer to keep apart from the first.
    private(set) var isChangingFile = false
    private(set) var changeFailure: String?

    /// Makes an empty file or a folder in the folder on screen.
    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        change(.create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// Gives something in the folder on screen a new name.
    ///
    /// The path is rebuilt from the folder and the new name rather than sent as a destination: a
    /// rename names a thing, and a path could name somewhere else. See
    /// ``RemoteFileOperation/rename(path:to:)``.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name), name != entry.name else { return }
        change(.rename(path: childPath(entry.name, of: folder), to: name), sessionID: id)
    }

    /// Removes something in the folder on screen, and everything inside it if it is a folder.
    ///
    /// The confirmation that makes this safe is the panel's, which is the one place both browsers
    /// go through. Nothing here asks again, and nothing here can: this is a `Task` with no view.
    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        change(.delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

    /// One change, awaited, with the folder re-listed afterwards either way.
    ///
    /// **Refused while one is already in the air**, because there is one flag saying so and two
    /// operations would share it — the second answer to arrive would clear a wait the first one
    /// owns, and the controls would go live while something was still running.
    ///
    /// The folder is re-asked on success *and* on failure. On success because that is what puts the
    /// new row on screen or takes the old one off; on failure because nothing here can tell what
    /// the server's filesystem looks like now — a delete that failed halfway has still changed
    /// something — and asking again is cheaper to get right than reasoning about it.
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
                // The shell this was asked through has gone, so there is nobody left to tell and
                // nothing left to re-list. The panel's own check for a dead shell is what says so.
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
        // A change in the air through a shell that has gone is a change that cannot be finished,
        // and `isChangingFile` is what disables the panel's controls — left set, the browser would
        // come back with a New Folder button that refuses to do anything.
        isChangingFile = false
        changeFailure = nil
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
    /// Three answers rather than one, because an intent cannot ask a question and a credential is
    /// the one thing it might need that is not in the request. With a shell already open it goes
    /// there; with a stored credential it connects; with neither it hands the user to the screen
    /// that *can* ask — which is the only honest thing a voice command can do about a secret. A
    /// stored key is a stored credential here, which is what stops a shortcut to a key-only server
    /// opening a password sheet the server would refuse.
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
    /// The credential comes from the shell that is open rather than from the keychain, because the
    /// common case is a user who did *not* ask to have it remembered: they are looking at a
    /// working session and want a second one, and being asked to type it again would make the
    /// second tab cost more than the first. Nothing is stored anywhere — this is the one that was
    /// just typed or just chosen, still in memory because its session is.
    @discardableResult
    func openAnotherShell(on terminal: SSHTerminal) -> SSHTerminal {
        // Deliberately not through ``requestOpen(_:)``, and so deliberately not past a lock either
        // — see there. This is the second shell on a machine the user is already looking at.
        open(terminal.host, credential: terminal.credential, remember: false)
    }

    /// Reflects open shells onto the Live Activity card.
    ///
    /// Called whenever a shell opens, connects, fails or closes. The representative name comes
    /// from the most recently opened shell that is still live, so opening a second server does
    /// not silently rename the card away from the one the user is looking at.
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

    /// Ends every shell. For the intent, which has no way to say *which* one.
    func closeAllShells() {
        for terminal in terminals {
            terminal.session.close()
        }
        terminals.removeAll()
        selectedTerminalID = nil
        TerminalActivity.shared.end()
        // Every host, because the loop above dropped every shell at once and there is no "last one"
        // left to work out per machine.
        let hosts = forwarders.keys
        Task { @MainActor in
            for host in hosts { await self.stopForwards(on: host) }
        }
        hostSessions.removeAll()
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
        // Nor is a forward that failed: the shell is still perfectly usable, and the sentence
        // belongs on the forward's own row in the ports sheet rather than here. Reaching this at
        // all would mean a forward error had escaped into the shell's event loop, which it cannot
        // do; the case is here so the switch stays exhaustive as the error type grows.
        case .forward(let reason):
            return SSHForwarder.describe(reason)
        }
    }
}
