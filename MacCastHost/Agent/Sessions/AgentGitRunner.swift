import Foundation
import MacCastKit

/// What a git run printed, cut at a byte limit.
struct AgentGitOutput {
    let data: Data
    /// The limit was reached and git was stopped.
    let truncated: Bool
    let succeeded: Bool

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Runs git with a fixed argument list, never through a shell, and never reads more than a limit.
enum AgentGitRunner {
    /// Nil when this Mac has no git that can be started without prompting for developer tools.
    private static let executable: URL? = {
        let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
        let path = AgentGitLocator.executable(exists: { FileManager.default.isExecutableFile(atPath: $0) }, developerDirectory: selected)
        return path.map { URL(fileURLWithPath: $0) }
    }()

    /// Switched off because a repository's own config may name a program for each of them, and looking at a folder must not run one.
    private static let safetyOptions = ["-c", "core.fsmonitor=false", "-c", "core.quotepath=false"]

    /// Nil when git cannot be started at all. With ``writes`` git's error text is read too, and the environment is what a commit's hooks and a push's credentials need.
    static func run(
        _ arguments: [String], in directory: URL, limit: Int, timeout: TimeInterval = 20, writes: Bool = false
    ) -> AgentGitOutput? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = safetyOptions + arguments
        process.currentDirectoryURL = directory
        var environment = [
            "PATH": writes ? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" : "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
        ]
        if writes, let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            environment["SSH_AUTH_SOCK"] = socket
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = writes ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Process.terminate() is safe from any thread; the compiler cannot know that.
        nonisolated(unsafe) let running = process
        let stop = DispatchWorkItem { running.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)

        var data = Data()
        var truncated = false
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count >= limit {
                truncated = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        stop.cancel()
        return AgentGitOutput(
            data: data.prefix(limit),
            truncated: truncated,
            succeeded: truncated || process.terminationStatus == 0
        )
    }
}
