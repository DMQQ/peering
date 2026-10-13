import Darwin
import Foundation
import PeeringKit

extension GroupProcess {
    struct Result {
        let output: Data
        let status: Int32
        let timedOut: Bool
        /// The output cap was reached, or `shouldAbort` asked for a stop.
        let stopped: Bool
    }

    /// Runs a command to the end, or to the first of: its timeout, the output cap, `shouldAbort`. Then the whole group is stopped and the pipe closed, so a hung child or a grandchild holding the pipe cannot stall the caller. Nil when it could not start.
    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        mergeStandardError: Bool = false,
        outputLimit: Int,
        timeout: TimeInterval,
        shouldAbort: (@Sendable () -> Bool)? = nil
    ) -> Result? {
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let statusBox = StatusBox()
        let child: GroupProcess
        do {
            child = try launch(
                executable: executable,
                arguments: arguments,
                directory: directory,
                environment: environment,
                standardInput: nil,
                standardOutput: pipe.fileHandleForWriting,
                standardError: mergeStandardError ? pipe.fileHandleForWriting : nil
            ) { status in
                statusBox.set(status)
                finished.signal()
            }
        } catch {
            return nil
        }
        // The parent's copy of the write end, or EOF never arrives.
        try? pipe.fileHandleForWriting.close()

        let collected = collect(from: pipe.fileHandleForReading.fileDescriptor, child: child, limit: outputLimit, timeout: timeout, shouldAbort: shouldAbort)
        try? pipe.fileHandleForReading.close()

        if finished.wait(timeout: .now() + 5) == .timedOut {
            child.terminateGroup(escalatingAfter: 0)
            _ = finished.wait(timeout: .now() + 2)
        }
        return Result(output: collected.data, status: statusBox.value, timedOut: collected.timedOut, stopped: collected.stopped)
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32 = -1  // guarded by lock
        func set(_ value: Int32) { lock.withLock { status = value } }
        var value: Int32 { lock.withLock { status } }
    }

    /// Polls rather than blocks in `read`: a descriptor that is never closed would otherwise never return.
    private static func collect(
        from descriptor: Int32, child: GroupProcess, limit: Int, timeout: TimeInterval, shouldAbort: (@Sendable () -> Bool)?
    ) -> (data: Data, timedOut: Bool, stopped: Bool) {
        var output = BoundedOutput(limit: limit)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var stopped = false
        var gaveUpWaitingAt: Date?

        while true {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 100)
            if ready > 0 {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                if !output.append(Data(buffer[0..<count])) {
                    stopped = true
                    child.terminateGroup(escalatingAfter: 2)
                    break
                }
                continue
            }
            if child.hasExited && ready == 0 { break }
            if !timedOut, Date() >= deadline {
                timedOut = true
                child.terminateGroup(escalatingAfter: 2)
                gaveUpWaitingAt = Date().addingTimeInterval(3)
            }
            if !stopped, !timedOut, shouldAbort?() == true {
                stopped = true
                child.terminateGroup(escalatingAfter: 2)
                break
            }
            if let gaveUpWaitingAt, Date() >= gaveUpWaitingAt { break }
        }
        return (output.data, timedOut, stopped)
    }
}
