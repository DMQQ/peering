import Foundation
import Testing

struct GroupProcessTerminationTests {
    private func launch(script: String, output: Pipe? = nil) throws -> (GroupProcess, AsyncStream<Int32>) {
        let (exits, continuation) = AsyncStream.makeStream(of: Int32.self)
        let process = try GroupProcess.launch(
            executable: "/bin/sh",
            arguments: ["-c", script],
            directory: URL(fileURLWithPath: "/"),
            environment: [:],
            standardInput: nil,
            standardOutput: output?.fileHandleForWriting,
            standardError: nil,
            onExit: { code in
                continuation.yield(code)
                continuation.finish()
            }
        )
        return (process, exits)
    }

    @Test func aGroupThatExitedOnTermLeavesNoKillScheduled() async throws {
        let output = Pipe()
        let (process, exits) = try launch(script: "echo ready; sleep 60", output: output)
        _ = output.fileHandleForReading.availableData
        process.terminateGroup(escalatingAfter: 3600)
        let code = await exits.first { _ in true }
        #expect(code == 128 + SIGTERM)
        #expect(process.escalationPending == false)
    }

    @Test func aKillIsNotScheduledForAGroupAlreadyGone() async throws {
        let (process, exits) = try launch(script: "exit 0")
        _ = await exits.first { _ in true }
        process.terminateGroup(escalatingAfter: 3600)
        #expect(process.escalationPending == false)
    }

    @Test func aGroupThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let output = Pipe()
        let (process, exits) = try launch(script: "trap '' TERM; echo ready; sleep 60", output: output)
        _ = output.fileHandleForReading.availableData
        process.terminateGroup(escalatingAfter: 0.1)
        let code = await exits.first { _ in true }
        #expect(code == 128 + SIGKILL)
    }
}
