import Darwin
import Foundation
import PeeringKit

/// A child started as the leader of its own process group, so stopping it reaches everything it started.
/// Foundation's `Process` cannot do this: `terminate()` signals the child alone, and a grandchild left holding a pipe open keeps a reader waiting for good.
final class GroupProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var exited = false  // guarded by lock
    private var escalation: DispatchWorkItem?  // guarded by lock
    private var escalationSettled = true  // guarded by lock: no kill is scheduled
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []  // guarded by lock

    var hasExited: Bool { lock.withLock { exited } }

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    /// A nil handle becomes /dev/null. `onExit` receives the exit code (128 plus the signal when killed) on a thread of its own.
    static func launch(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        standardInput: FileHandle?,
        standardOutput: FileHandle?,
        standardError: FileHandle?,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> GroupProcess {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Closing everything not named below keeps the child from inheriting a pipe end that would stop an EOF arriving.
        // An ignored or blocked SIGTERM is inherited across exec, which would make the grace period meaningless.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noBlockedSignals = sigset_t()
        sigemptyset(&noBlockedSignals)
        posix_spawnattr_setsigmask(&attributes, &noBlockedSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, handle) in [(0, standardInput), (1, standardOutput), (2, standardError)] as [(Int32, FileHandle?)] {
            if let handle {
                posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_RDWR, 0)
            }
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }

        let child = pid
        let process = GroupProcess(processIdentifier: child)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            process.leaderReaped()
            onExit(ProcessWaitStatus.exitCode(fromWaitStatus: status))
        }
        return process
    }

    /// SIGTERM to the whole group, then SIGKILL to it after the grace if a member is still alive. The kill is dropped as soon as the group is gone, because its id may by then belong to an unrelated group.
    func terminateGroup(escalatingAfter grace: TimeInterval = 5) {
        signalGroup(SIGTERM)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.groupExists { self.signalGroup(SIGKILL) }
            self.settleEscalation()
        }
        let (alreadyGone, watchGroup) = lock.withLock {
            escalation?.cancel()
            escalation = work
            escalationSettled = false
            let gone = exited && !groupExists
            if gone { escalationSettled = true }
            return (gone, exited && !gone)
        }
        if alreadyGone {
            work.cancel()
            resumeSettleWaiters()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace, execute: work)
        if watchGroup { watchUntilGroupGone() }
    }

    var escalationPending: Bool { lock.withLock { escalation != nil && !escalationSettled } }

    /// Returns once no kill is scheduled any more: it fired, or the group was found gone and it was cancelled.
    func waitUntilEscalationSettled() async {
        await withCheckedContinuation { continuation in
            let settled = lock.withLock { () -> Bool in
                if escalation == nil || escalationSettled { return true }
                settleWaiters.append(continuation)
                return false
            }
            if settled { continuation.resume() }
        }
    }

    private var groupExists: Bool { killpg(processIdentifier, 0) == 0 }

    private func leaderReaped() {
        let watchGroup = lock.withLock { () -> Bool in
            exited = true
            guard let work = escalation, !escalationSettled else { return false }
            if groupExists { return true }
            work.cancel()
            escalationSettled = true
            return false
        }
        resumeSettleWaiters()
        if watchGroup { watchUntilGroupGone() }
    }

    /// Members of the group can outlive the leader for a moment (a child still exiting), so the kill is cancelled as soon as the last one is gone and not left waiting for the grace.
    private func watchUntilGroupGone() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            let keepWatching = self.lock.withLock { () -> Bool in
                guard let work = self.escalation, !self.escalationSettled else { return false }
                if self.groupExists { return true }
                work.cancel()
                self.escalationSettled = true
                return false
            }
            if keepWatching { self.watchUntilGroupGone() } else { self.resumeSettleWaiters() }
        }
    }

    private func settleEscalation() {
        lock.withLock { escalationSettled = true }
        resumeSettleWaiters()
    }

    private func resumeSettleWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard escalationSettled else { return [] }
            defer { settleWaiters = [] }
            return settleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private func signalGroup(_ signal: Int32) {
        // Sent even after the leader is reaped: grandchildren outlive it, and a group id cannot be reused while any member remains.
        killpg(processIdentifier, signal)
    }
}
