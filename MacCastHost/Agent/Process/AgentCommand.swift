import Foundation

/// A short command run to completion, for the facts a CLI keeps behind a subcommand.
enum AgentCommand {
    /// Standard output, or nil when it could not start, failed, or took longer than `timeout`.
    static func output(
        binary: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: TimeInterval = 10
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read before waiting: a full pipe would block the child and the wait together.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
