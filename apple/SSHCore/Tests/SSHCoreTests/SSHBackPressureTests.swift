import Foundation
import Testing

@testable import SSHCore

@Suite("SSH requests that cannot hang")
struct SSHBackPressureTests {
    @Test func aReplyResumesOnlyOnceWhenTheDeadlineAndTheAnswerRace() async throws {
        let result: SSHBrowseResult = try await withCheckedThrowingContinuation { continuation in
            let reply = SSHBrowseReply(continuation)
            reply.resume(returning: .changed(note: "first"))
            reply.resume(throwing: SSHSessionError.notConnected)
            reply.resume(returning: .changed(note: "second"))
        }
        guard case .changed(let note) = result else {
            Issue.record("expected the first answer")
            return
        }
        #expect(note == "first")
    }

    @Test func aReplyReportsWhenItWasAnswered() async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHBrowseResult, any Error>) in
            let reply = SSHBrowseReply(continuation)
            #expect(!reply.isAnswered)
            reply.resume(returning: .changed(note: ""))
            #expect(reply.isAnswered)
        }
    }

    @Test func aReplyPastItsDeadlineFailsWithoutAnAnswer() async {
        await #expect(throws: SSHSessionError.self) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHBrowseResult, any Error>) in
                SSHBrowseReply(continuation).expire(after: .zero)
            }
        }
    }

    @Test func droppedEventsLeaveOneMarkerInsteadOfNothing() async {
        let (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let sink = SSHEventSink(continuation)
        for _ in 0..<5 { sink.yield(.output(Data([1]))) }
        sink.finish()

        var sawMarker = false
        for await event in events {
            if case .outputDropped = event { sawMarker = true }
        }
        #expect(sawMarker)
    }

    @Test func nothingIsMarkedWhenNothingIsDropped() async {
        let (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let sink = SSHEventSink(continuation)
        for _ in 0..<3 { sink.yield(.output(Data([1]))) }
        sink.finish()

        var markers = 0
        for await event in events {
            if case .outputDropped = event { markers += 1 }
        }
        #expect(markers == 0)
    }
}
