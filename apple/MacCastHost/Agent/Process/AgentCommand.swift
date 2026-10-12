import Foundation

/// A short command run to completion, for the facts a CLI keeps behind a subcommand.
enum AgentCommand {
    static let defaultOutputLimit = 8 * 1024 * 1024

    /// Standard output, or nil when it could not start, failed, took longer than `timeout`, printed more than `outputLimit` bytes, or `shouldAbort` said stop. The whole process group is stopped in each of those cases.
    static func output(
        binary: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: TimeInterval = 10,
        outputLimit: Int = defaultOutputLimit,
        shouldAbort: (@Sendable () -> Bool)? = nil
    ) -> Data? {
        guard let result = GroupProcess.run(
            executable: binary,
            arguments: arguments,
            directory: directory,
            environment: environment,
            outputLimit: outputLimit,
            timeout: timeout,
            shouldAbort: shouldAbort
        ) else { return nil }
        return result.status == 0 && !result.timedOut && !result.stopped ? result.output : nil
    }
}
