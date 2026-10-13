import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

struct HostLiveActivityPublisherTests {
    /// Stands in for the relay link: records what the publisher handed over and lets the test decide when each push counts as sent.
    private final class FakeLink: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []  // guarded by lock
        private var pendingDone: [@Sendable () -> Void] = []  // guarded by lock
        let endSent: AsyncStream<Void>
        private let endSentContinuation: AsyncStream<Void>.Continuation

        init() {
            (endSent, endSentContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        var events: [String] { lock.withLock { log } }
        func note(_ event: String) { lock.withLock { log.append(event) } }

        func send(_ push: RelayActivityPush, _ done: @escaping @Sendable () -> Void) {
            lock.withLock {
                log.append("send:\(push.event.rawValue)")
                pendingDone.append(done)
            }
            if push.event == .end { endSentContinuation.yield() }
        }

        func finishAllSends() {
            let done = lock.withLock { () -> [@Sendable () -> Void] in
                defer { pendingDone.removeAll() }
                return pendingDone
            }
            for item in done { item() }
        }
    }

    private func publisher(_ link: FakeLink, flushTimeout: TimeInterval = 5) -> HostLiveActivityPublisher {
        HostLiveActivityPublisher(
            hostID: "host",
            flushTimeout: flushTimeout,
            presence: { _ in .background },
            observedChats: { _ in [] },
            send: { push, done in link.send(push, done) }
        )
    }

    private func showCard(on publisher: HostLiveActivityPublisher, client: String = "phone") {
        publisher.tokens(
            clientID: client,
            ActivityTokenPayload(activity: .session, pushToken: "token-\(client)", pushToStartToken: nil, environment: .production)
        )
        publisher.sessionBegan(clientID: client, viaRelay: false)
    }

    private func stopping(_ publisher: HostLiveActivityPublisher, link: FakeLink) -> AsyncStream<Void> {
        let (completed, continuation) = AsyncStream.makeStream(of: Void.self)
        publisher.hostStopping {
            link.note("relay closed")
            continuation.yield()
        }
        return completed
    }

    @Test func theRelayLinkClosesOnlyAfterTheEndEventsHaveBeenSent() async {
        let link = FakeLink()
        let publisher = publisher(link)
        showCard(on: publisher)
        let completed = stopping(publisher, link: link)

        for await _ in link.endSent { break }
        #expect(link.events == ["send:update", "send:end"])

        link.finishAllSends()
        for await _ in completed { break }
        #expect(link.events == ["send:update", "send:end", "relay closed"])
    }

    @Test func aStopRightAfterAnUpdateStillSendsTheEnd() async {
        let link = FakeLink()
        let publisher = publisher(link)
        showCard(on: publisher)
        let completed = stopping(publisher, link: link)

        for await _ in link.endSent { break }
        link.finishAllSends()
        for await _ in completed { break }
        #expect(link.events.filter { $0 == "send:end" }.count == 1)
    }

    @Test func aPushThatNeverCompletesDoesNotHoldTheRelayLinkOpenForever() async {
        let link = FakeLink()
        let publisher = publisher(link, flushTimeout: 0.05)
        showCard(on: publisher)
        let completed = stopping(publisher, link: link)

        for await _ in completed { break }
        #expect(link.events == ["send:update", "send:end", "relay closed"])
    }

    @Test func stoppingWithNoCardsClosesTheLinkAtOnce() async {
        let link = FakeLink()
        let publisher = publisher(link)
        let completed = stopping(publisher, link: link)

        for await _ in completed { break }
        #expect(link.events == ["relay closed"])
    }

    @Test func everyCardIsEndedAndEveryWaiterIsToldOnce() async {
        let link = FakeLink()
        let publisher = publisher(link)
        showCard(on: publisher, client: "first")
        showCard(on: publisher, client: "second")
        let first = stopping(publisher, link: link)
        let second = stopping(publisher, link: link)

        for await _ in link.endSent { break }
        for await _ in link.endSent { break }
        link.finishAllSends()
        for await _ in first { break }
        for await _ in second { break }
        let ends = link.events.filter { $0 == "send:end" }
        let closes = link.events.filter { $0 == "relay closed" }
        #expect(ends.count == 2)
        #expect(closes.count == 2)
        #expect(link.events.last == "relay closed")
    }
}
