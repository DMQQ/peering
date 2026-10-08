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
    @ObservationIgnored var isRecorded = false

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

    func append(_ chunk: Data) -> TerminalAttentionKind? {
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

    func userDidRespond() {
        attentionDetector.userDidRespond()
    }

    func setPhase(_ phase: Phase) {
        self.phase = phase
    }
}

struct SSHKeyPrompt: Identifiable {
    let id = UUID()
    let prompt: SSHHostKeyPrompt
}
