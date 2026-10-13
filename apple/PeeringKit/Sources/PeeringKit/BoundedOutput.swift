import Foundation

/// What a child process printed, kept up to a byte cap so a command that never stops talking cannot fill memory.
public struct BoundedOutput: Sendable, Equatable {
    public let limit: Int
    public private(set) var data = Data()
    public private(set) var exceeded = false

    public init(limit: Int) {
        self.limit = limit
    }

    /// Returns false once the cap is passed; the caller stops the child then.
    @discardableResult
    public mutating func append(_ chunk: Data) -> Bool {
        let room = limit - data.count
        if chunk.count > room {
            data.append(chunk.prefix(max(0, room)))
            exceeded = true
            return false
        }
        data.append(chunk)
        return true
    }
}

/// A `waitpid` status word, read without the C macros Swift cannot import.
public enum ProcessWaitStatus {
    /// The exit code, or 128 plus the signal that ended the process.
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
