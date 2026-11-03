import Foundation
import RemoteCore

/// What one turn did, gathered from its tool calls, for the single line a finished notification and the Live Activity show.
///
/// Only a closed set of facts: files changed, tests passed or failed, a commit left unpushed. Nothing the agent or the person wrote.
public struct AgentTurnRecap: Equatable, Sendable {
    public enum Tests: Equatable, Sendable {
        case passed
        case failed
    }

    private enum Kind: Hashable, Sendable {
        case test
        case commit
        case push
    }

    public private(set) var editedFiles: Set<String> = []
    public private(set) var tests: Tests?
    public private(set) var committed = false
    public private(set) var pushed = false
    private var running: [String: Set<Kind>] = [:]

    public init() {}

    public var waitingToPush: Bool { committed && !pushed }

    public mutating func started(_ call: AgentToolCall) {
        if AgentTurnDigest.edits(call), let path = call.filePath { editedFiles.insert(path) }
        guard let command = call.detail, Self.isShell(call.name) else { return }
        let kinds = Self.kinds(of: command)
        if !kinds.isEmpty { running[call.id] = kinds }
    }

    public mutating func finished(callID: String, ok: Bool) {
        for kind in running.removeValue(forKey: callID) ?? [] { record(kind, ok: ok) }
    }

    private mutating func record(_ kind: Kind, ok: Bool) {
        switch kind {
        case .test:
            // One failing run is the news, even when a later run passes.
            if tests != .failed { tests = ok ? .passed : .failed }
        case .commit:
            if ok { committed = true }
        case .push:
            if ok { pushed = true }
        }
    }

    /// "Changed 4 files, tests passed, waiting to push", or nil for a turn that did none of these.
    public func line(words: AgentRecapWords = .english) -> String? {
        var parts: [String] = []
        if !editedFiles.isEmpty { parts.append(words.changedFiles(editedFiles.count)) }
        switch tests {
        case .passed: parts.append(words.testsPassed)
        case .failed: parts.append(words.testsFailed)
        case nil: break
        }
        if waitingToPush { parts.append(words.waitingToPush) }
        guard !parts.isEmpty else { return nil }
        return words.join(parts)
    }

    private static let shellTools: Set<String> = ["Bash", "command_execution", "shell", "bash"]

    private static func isShell(_ name: String) -> Bool {
        shellTools.contains(name)
    }

    private static let testCommands: [[String]] = [
        "swift test", "npm test", "npm run test", "yarn test", "pnpm test", "bun test", "pytest", "cargo test",
        "go test", "xcodebuild test", "jest", "vitest", "rspec", "gradle test", "./gradlew test", "mvn test", "make test",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Words before the program that do not change which program runs.
    private static let launchers: Set<String> = ["sudo", "env", "time", "npx", "bunx", "exec", "command"]

    private static func kinds(of command: String) -> Set<Kind> {
        let segments = command.lowercased().split { "\n;|&".contains($0) }
        return Set(segments.compactMap { kind(ofSegment: words(of: $0)) })
    }

    private static func words(of segment: Substring) -> [String] {
        let all = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(all.drop { launchers.contains($0) || $0.contains("=") && !$0.hasPrefix("-") })
    }

    private static func kind(ofSegment words: [String]) -> Kind? {
        guard let program = words.first else { return nil }
        if program == "git", let verb = gitVerb(Array(words.dropFirst())) {
            return verb == "push" ? .push : verb == "commit" ? .commit : nil
        }
        return testCommands.contains { words.starts(with: $0) } ? .test : nil
    }

    /// `git -C dir commit` names the verb after its options.
    private static func gitVerb(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += ["-c", "-C"].contains(arguments[index]) ? 2 : 1
        }
        return index < arguments.count ? arguments[index] : nil
    }
}
