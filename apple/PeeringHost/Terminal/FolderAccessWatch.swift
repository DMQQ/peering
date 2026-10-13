import Foundation

/// Reading a protected folder can park on the Mac's "Peering would like to access files in your Desktop folder" dialog, which nobody holding the phone can see. This says so after a short wait instead of leaving the caller in silence.
enum FolderAccessWatch {
    static let slowAfter: TimeInterval = 2.5

    static let listingMessage = "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here."
    static let chatMessage = "Waiting for your Mac. macOS asks once per folder before an app may open it: choose Allow on the Mac. Peering and the agent only read what you ask them to."
    static let deniedMessage = "Peering could not read this folder. If macOS blocked it, you can allow it in System Settings, Privacy & Security, Files and Folders."

    /// Whether the folder is certainly gone. A protected folder the Mac has not yet allowed fails `stat` with a permission error, and reading that as "missing" hid every chat started under Desktop or Documents.
    static func isMissing(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0 else { return (info.st_mode & S_IFMT) != S_IFDIR }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// Reads the folder once so macOS asks about it now, while the phone waits on a list, and not in the middle of a conversation. Returns whether it could be read.
    @discardableResult
    static func requestAccess(to path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Runs `work` here and calls `slow` once if it has not finished by then. `slow` never runs after `work` has returned, so its message cannot arrive behind the answer.
    static func perform<Result>(slow: @escaping @Sendable () -> Void, work: () -> Result) -> Result {
        let lock = NSLock()
        var finished = false
        let timer = DispatchWorkItem {
            lock.withLock { if !finished { slow() } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + slowAfter, execute: timer)
        let result = work()
        lock.withLock { finished = true }
        timer.cancel()
        return result
    }

    static func run<Result: Sendable>(
        slow: @escaping @Sendable () -> Void,
        work: @escaping @Sendable () -> Result,
        done: @escaping @Sendable (Result) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            done(perform(slow: slow, work: work))
        }
    }
}
