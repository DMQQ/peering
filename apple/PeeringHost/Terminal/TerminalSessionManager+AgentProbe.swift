import Foundation
import PeeringKit

extension TerminalSessionManager {
    private static let agentNames = ["claude", "codex", "opencode", "hermes", "gemini", "aider"]
    private static let agentProbe = CachedProbe<[String]>(lifetime: 60)

    /// Each probe starts an interactive login shell, so callers share one in flight and its answer for a minute.
    static func probeAgents(_ reply: @escaping @Sendable ([String]) -> Void) {
        switch agentProbe.request(at: ProcessInfo.processInfo.systemUptime, reply: reply) {
        case .answer(let names):
            reply(names)
        case .wait:
            return
        case .start:
            DispatchQueue.global(qos: .utility).async {
                let found = installedAgents()
                agentProbe.finish(found, at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// Every name when the shell cannot be asked, so a Mac with an odd shell still offers the choices.
    private static func installedAgents() -> [String] {
        let loop = "for c in \(agentNames.joined(separator: " ")); do command -v $c >/dev/null 2>&1 && echo $c; done"
        guard let result = GroupProcess.run(
            executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            arguments: ["-l", "-i", "-c", loop],
            directory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            outputLimit: 64 * 1024,
            timeout: 6
        ), !result.timedOut else { return agentNames }
        let output = String(decoding: result.output, as: UTF8.self)
        return output.split(separator: "\n").map(String.init).filter { agentNames.contains($0) }
    }
}
