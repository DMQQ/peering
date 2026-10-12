import Darwin
import Foundation
import MacCastKit

/// A child started as the leader of its own process group, so stopping it reaches everything it started.
/// Foundation's `Process` cannot do this: `terminate()` signals the child alone, and a grandchild left holding a pipe open keeps a reader waiting for good.
final class GroupProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var exited = false  // guarded by lock

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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
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

        let process = GroupProcess(processIdentifier: pid)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            process.lock.withLock { process.exited = true }
            onExit(ProcessWaitStatus.exitCode(fromWaitStatus: status))
        }
        return process
    }

    /// SIGTERM to the whole group, then SIGKILL to it if anything is still alive after the grace.
    func terminateGroup(escalatingAfter grace: TimeInterval = 5) {
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            self?.signalGroup(SIGKILL)
        }
    }

    private func signalGroup(_ signal: Int32) {
        // Sent even after the leader is reaped: grandchildren outlive it, and a group id cannot be reused while any member remains.
        killpg(processIdentifier, signal)
    }
}
