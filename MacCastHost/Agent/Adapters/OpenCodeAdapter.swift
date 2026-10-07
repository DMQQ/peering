import Foundation
import MacCastKit
import RemoteCore

/// Run mode has no approval channel: without `--auto` a call needing one is rejected as a failed tool, the safe direction; `--auto` is deliberately not passed.
final class OpenCodeAdapter: PerTurnAdapter, @unchecked Sendable {
    private var stream: AgentOpenCodeStream
    private var contextWindows: [String: Int] = [:]

    override class var command: String { "opencode" }
    override class var displayName: String { "OpenCode" }

    override init(directory: URL, resume: AgentResume?) {
        stream = AgentOpenCodeStream(directory: directory.path, cliSessionID: resume?.cliSessionID)
        super.init(directory: directory, resume: resume)
    }

    override func arguments(for text: String) -> [String] {
        // `--` before the text so a prompt starting with a dash is not read as a flag.
        var arguments = ["run", "--format", "json"]
        if permissionMode == .auto { arguments += ["--auto"] }
        if let model { arguments += ["-m", model] }
        if let session = stream.cliSessionID { arguments += ["-s", session] }
        arguments += ["--", text]
        return arguments
    }

    override func receive(line: String) -> [AgentStreamEvent.Payload] {
        stream.receive(line: line)
    }

    /// The totals now, and the context window once the model's own listing has been asked: that
    /// takes two short commands, so it follows on rather than holding the first report back.
    override func turnProcessEnded() {
        let baseUsage = stream.usage
        onUsage?(baseUsage)
        guard let binary, let session = stream.cliSessionID else { return }
        let environment = AgentEnvironment.shared.variables()
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = AgentCommand.output(
                binary: binary, arguments: ["export", session], directory: directory, environment: environment
            ), let model = AgentOpenCodeModels.lastModel(inExport: data) else { return }
            var window = self?.queue.sync { self?.contextWindows[model.listed] }
            if window == nil,
               let listing = AgentCommand.output(
                   binary: binary, arguments: ["models", model.provider, "--verbose"],
                   directory: directory, environment: environment
               ) {
                window = AgentOpenCodeModels.contextWindow(
                    of: model, inListing: String(decoding: listing, as: UTF8.self)
                )
            }
            guard let window else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.contextWindows[model.listed] = window
                var usage = baseUsage
                usage.contextWindowTokens = window
                self.onUsage?(usage)
            }
        }
    }
}
