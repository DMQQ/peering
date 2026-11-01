import Foundation
import PeeringKit

/// Reading a protected folder can park on the Mac's "Peering would like to access files in your Desktop folder" dialog, which nobody holding the phone can see. This says so after a short wait instead of leaving the caller in silence.
enum FolderAccessWatch {
    static let slowAfter: TimeInterval = 2.5

    static let listingMessage = "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here."
    static let chatMessage = "Waiting for your Mac. macOS asks once per folder before an app may open it: choose Allow on the Mac. Peering and the agent only read what you ask them to."
    static let deniedMessage = "Peering could not read this folder. If macOS blocked it, you can allow it in System Settings, Privacy & Security, Files and Folders."

    /// Whether the folder is certainly gone. A protected folder not yet allowed fails `stat` with a permission error, which is not missing.
    static func isMissing(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0 else { return (info.st_mode & S_IFMT) != S_IFDIR }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// Reads the folder once so macOS asks about it now, while the phone waits on a list, and not in the middle of a conversation. Returns whether it could be read.
    /// One parked read per protected folder: a later caller waits for it, and by then macOS has its answer and does not ask again.
    @discardableResult
    static func requestAccess(to path: String) -> Bool {
        let key = FolderAccessSlots.key(for: path, home: NSHomeDirectory())
        reading.lock()
        while !slots.claim(key) { reading.wait() }
        reading.unlock()
        defer {
            reading.lock()
            slots.release(key)
            reading.broadcast()
            reading.unlock()
        }
        return isReadable(path)
    }

    /// For a caller that only wants the question asked: returns at once when a read of the same folder is already waiting on it.
    static func askUnlessAsking(about path: String) {
        let key = FolderAccessSlots.key(for: path, home: NSHomeDirectory())
        let claimed = reading.withLock { slots.claim(key) }
        guard claimed else { return }
        _ = isReadable(path)
        reading.withLock { slots.release(key) }
        reading.broadcast()
    }

    private static func isReadable(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Guarded by `reading`.
    nonisolated(unsafe) private static var slots = FolderAccessSlots()
    private static let reading = NSCondition()

    /// Runs `work` here and calls `slow` once if it has not finished by then. `slow` never runs after `work` has returned, so its message cannot arrive behind the answer.
    static func perform<Result>(slow: @escaping @Sendable () -> Void, work: () -> Result) -> Result {
        let condition = NSCondition()
        var finished = false
        var slowRunning = false
        let timer = DispatchWorkItem {
            let late = condition.withLock { () -> Bool in
                slowRunning = !finished
                return slowRunning
            }
            guard late else { return }
            slow()
            condition.withLock { slowRunning = false }
            condition.broadcast()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + slowAfter, execute: timer)
        let result = work()
        timer.cancel()
        condition.lock()
        finished = true
        // Waits out a `slow` already started, so its message still lands ahead of the answer.
        while slowRunning { condition.wait() }
        condition.unlock()
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
