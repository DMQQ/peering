import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

/// The plans run against real git in a throwaway repository whose upstream is a bare repository beside it.
@Suite struct AgentGitScratchRepoTests {
    private struct Scratch {
        let root: URL
        var work: URL { root.appendingPathComponent("work") }
        var bare: URL { root.appendingPathComponent("remote.git") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("git-scratch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
            _ = git(["init", "--bare", "-b", "main", bare.path], in: root)
            _ = git(["init", "-b", "main"], in: work)
            _ = git(["remote", "add", "origin", bare.path], in: work)
            write("seed.txt", "seed\n")
            _ = git(["add", "--", "seed.txt"], in: work)
            _ = git(["commit", "-m", "Seed"], in: work)
            _ = git(["push", "-u", "origin", "main"], in: work)
        }

        func write(_ name: String, _ text: String) {
            let url = work.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) -> (ok: Bool, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.invalid",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) -> String { run(arguments, in: directory).text }

    private func branch(in work: URL) -> AgentGitBranch? {
        let status = Self.git(["status", "--porcelain=v2", "--branch", "--untracked-files=no"], in: work)
        let remote = Self.git(["config", "--get", "branch.main.remote"], in: work)
        let merge = Self.git(["config", "--get", "branch.main.merge"], in: work)
        return AgentGitPush.branch(statusHeaders: status, remote: remote, mergeRef: merge)
    }

    @Test func commitsOnlyTheChosenFilesAndLeavesTheRest() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.write("a.txt", "a\n")
        scratch.write("b.txt", "b\n")
        scratch.write("sub/c.txt", "c\n")
        _ = Self.git(["add", "--", "b.txt"], in: scratch.work)

        let plan = try AgentGitCommit.plan(paths: ["a.txt", "sub/c.txt"], message: "Add a.txt and c.txt").get()
        #expect(Self.run(plan.stage, in: scratch.work).ok)
        #expect(Self.run(plan.commit, in: scratch.work).ok)

        let committed = Self.git(["show", "--name-only", "--format=%s", "HEAD"], in: scratch.work)
        #expect(committed.contains("Add a.txt and c.txt"))
        #expect(committed.contains("a.txt") && committed.contains("sub/c.txt"))
        #expect(!committed.contains("b.txt"))
        #expect(Self.git(["status", "--porcelain"], in: scratch.work).contains("A  b.txt"))
    }

    @Test func aPathspecLookingNameIsOnlyAFileName() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.write("a.txt", "a\n")
        scratch.write("b.txt", "b\n")
        let plan = try AgentGitCommit.plan(paths: [":(glob)*.txt"], message: "x").get()
        #expect(!Self.run(plan.stage, in: scratch.work).ok)
        #expect(!Self.git(["status", "--porcelain"], in: scratch.work).contains("A  "))
    }

    @Test func aDeletionIsCommitted() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.removeItem(at: scratch.work.appendingPathComponent("seed.txt"))
        let plan = try AgentGitCommit.plan(paths: ["seed.txt"], message: "Remove seed.txt").get()
        #expect(Self.run(plan.stage, in: scratch.work).ok)
        #expect(Self.run(plan.commit, in: scratch.work).ok)
        #expect(Self.git(["show", "--name-status", "--format=", "HEAD"], in: scratch.work).contains("D\tseed.txt"))
    }

    @Test func pushSendsTheBranchToItsUpstreamOnly() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.write("a.txt", "a\n")
        let plan = try AgentGitCommit.plan(paths: ["a.txt"], message: "Add a.txt").get()
        #expect(Self.run(plan.stage, in: scratch.work).ok)
        #expect(Self.run(plan.commit, in: scratch.work).ok)
        _ = Self.git(["tag", "local-only"], in: scratch.work)

        let current = try #require(branch(in: scratch.work))
        #expect(current.ahead == 1)
        let arguments = try AgentGitPush.arguments(for: current).get()
        #expect(Self.run(arguments, in: scratch.work).ok)

        #expect(Self.git(["rev-parse", "main"], in: scratch.bare) == Self.git(["rev-parse", "main"], in: scratch.work))
        #expect(!Self.git(["tag"], in: scratch.bare).contains("local-only"))
        #expect(try #require(branch(in: scratch.work)).ahead == 0)
    }

    @Test func aConfiguredForcingRefspecIsNeverConsulted() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        _ = Self.git(["config", "remote.origin.push", "+refs/heads/*:refs/heads/*"], in: scratch.work)
        _ = Self.git(["config", "push.followTags", "true"], in: scratch.work)
        scratch.write("a.txt", "a\n")
        let plan = try AgentGitCommit.plan(paths: ["a.txt"], message: "Add a.txt").get()
        _ = Self.run(plan.stage, in: scratch.work)
        _ = Self.run(plan.commit, in: scratch.work)

        // Someone else moves the remote on, so a forced push would overwrite it and a plain one must be refused.
        let other = scratch.root.appendingPathComponent("other")
        _ = Self.git(["clone", scratch.bare.path, other.path], in: scratch.root)
        try "x\n".write(to: other.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = Self.git(["add", "--", "x.txt"], in: other)
        _ = Self.git(["commit", "-m", "Elsewhere"], in: other)
        _ = Self.git(["push", "origin", "main"], in: other)
        let remoteHead = Self.git(["rev-parse", "main"], in: scratch.bare)

        let arguments = try AgentGitPush.arguments(for: try #require(branch(in: scratch.work))).get()
        #expect(!Self.run(arguments, in: scratch.work).ok)
        #expect(Self.git(["rev-parse", "main"], in: scratch.bare) == remoteHead)
    }

    @Test func aBranchWithNoUpstreamHasNothingToPush() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        _ = Self.git(["checkout", "-b", "topic"], in: scratch.work)
        let status = Self.git(["status", "--porcelain=v2", "--branch"], in: scratch.work)
        let topic = try #require(AgentGitPush.branch(statusHeaders: status, remote: nil, mergeRef: nil))
        #expect(AgentGitPush.arguments(for: topic) == .failure(.noUpstream))

        _ = Self.git(["checkout", "--detach"], in: scratch.work)
        let detached = Self.git(["status", "--porcelain=v2", "--branch"], in: scratch.work)
        let head = try #require(AgentGitPush.branch(statusHeaders: detached, remote: nil, mergeRef: nil))
        #expect(AgentGitPush.arguments(for: head) == .failure(.detachedHead))
    }
}
