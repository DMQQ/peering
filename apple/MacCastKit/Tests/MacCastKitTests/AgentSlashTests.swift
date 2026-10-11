import RemoteCore
import Testing

@testable import MacCastKit

struct AgentSlashTests {
    private func entry(_ name: String, folder: Bool = false) -> RemoteDirectoryEntry {
        RemoteDirectoryEntry(name: name, isDirectory: folder, isSymlink: false, size: 0, permissions: "rw-r--r--", modified: nil)
    }

    @Test func queryIsOneWordStartingWithASlash() {
        #expect(AgentSlash.query("/mod") == "mod")
        #expect(AgentSlash.query("/") == "")
        #expect(AgentSlash.query("/model x") == nil)
        #expect(AgentSlash.query("hello") == nil)
    }

    @Test func homeIsReadOffTheProjectPath() {
        #expect(AgentSlash.home(of: "/Users/me/app") == "/Users/me")
        #expect(AgentSlash.home(of: "/opt/app") == nil)
        #expect(AgentSlash.home(of: "/Users") == nil)
    }

    @Test func onlyClaudeHasFoldersToRead() {
        #expect(AgentSlash.folders(project: "/Users/me/app", agentID: "codex").isEmpty)
        #expect(AgentSlash.folders(project: "/Users/me/app/", agentID: "claude") == [
            "/Users/me/app/.claude/commands", "/Users/me/app/.claude/skills",
            "/Users/me/.claude/commands", "/Users/me/.claude/skills",
        ])
    }

    @Test func appCommandsAreOfferedByWhatTheHostSupports() {
        let names = AgentSlash.suggestions(
            for: "", agentID: "codex", project: "/p", offersUsage: false, offersModel: true, listing: { _ in nil }
        ).map(\.name)
        #expect(names == ["model", "rename"])
    }

    @Test func claudeAddsItsBuiltInsAndReadsCommandsAndSkills() {
        let found = AgentSlash.suggestions(
            for: "", agentID: "claude", project: "/Users/me/app", offersUsage: true, offersModel: true,
            listing: { path in
                switch path {
                case "/Users/me/app/.claude/commands": [entry("ship.md"), entry("notes.txt"), entry(".hidden.md")]
                case "/Users/me/.claude/skills": [entry("deploy", folder: true), entry("loose.md")]
                default: nil
                }
            }
        )
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(byName["ship"]?.kind == .command)
        #expect(byName["ship"]?.detail == .thisProject)
        #expect(byName["deploy"]?.kind == .skill)
        #expect(byName["deploy"]?.detail == .yours)
        #expect(byName["compact"]?.kind == .builtin)
        #expect(byName["notes"] == nil)
        #expect(byName["hidden"] == nil)
        #expect(byName["loose"] == nil)
    }

    @Test func appFirstThenBuiltInsAndTypedPrefixLeads() {
        let all = AgentSlash.suggestions(
            for: "", agentID: "claude", project: "/p", offersUsage: true, offersModel: true, listing: { _ in nil }
        ).map(\.name)
        #expect(all == ["model", "rename", "usage", "clear", "compact"])
        let narrowed = AgentSlash.suggestions(
            for: "c", agentID: "claude", project: "/p", offersUsage: true, offersModel: true, listing: { _ in nil }
        ).map(\.name)
        #expect(narrowed == ["clear", "compact"])
    }

    @Test func aProjectCommandShadowsAUserOneOfTheSameName() {
        let found = AgentSlash.suggestions(
            for: "ship", agentID: "claude", project: "/Users/me/app", offersUsage: false, offersModel: false,
            listing: { path in
                path.hasSuffix("/commands") ? [entry("ship.md")] : nil
            }
        )
        #expect(found.count == 1)
        #expect(found.first?.detail == .thisProject)
    }
}
