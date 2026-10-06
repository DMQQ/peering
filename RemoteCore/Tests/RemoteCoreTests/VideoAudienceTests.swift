import Foundation
import Testing

@testable import RemoteCore

/// A class, because the audience compares identity: matching connections by value would attach one that has gone.
private final class Connection {
    let client: String

    init(_ client: String) { self.client = client }
}

@Suite("The video audience")
struct VideoAudienceTests {
    @Test("a connection with a description is served straight away")
    func describedConnectionIsAttached() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")

        audience.connected(phone, described: true)

        #expect(audience.served === phone)
        #expect(!audience.isIdle)
    }

    @Test("a connection with no description waits for one")
    func undescribedConnectionWaits() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")

        audience.connected(phone, described: false)

        #expect(audience.served === phone, "it is still the connection the picture is owed to")
        #expect(audience.described() === phone)
        #expect(audience.described() == nil, "and there is nothing left waiting for one")
    }

    @Test("a pause takes the last client out of the audience")
    func pauseEmptiesTheAudience() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")
        audience.connected(phone, described: true)
        let generation = audience.generation

        #expect(audience.pause(phone) == .attached)
        #expect(audience.isIdle, "nobody is asking for frames, so there is nothing to capture for")
        #expect(audience.generation > generation, "and work queued for that audience is now void")
        #expect(
            audience.pausedConnections.contains { $0 === phone },
            "the connection is still open, and it is what a resume attaches"
        )
    }

    @Test("pausing a client that is not being served changes nothing")
    func pauseFromAnUnservedClient() {
        var audience = VideoAudience<Connection>()
        let first = Connection("phone-a")
        let second = Connection("phone-b")
        audience.connected(first, described: true)
        audience.connected(second, described: true)
        let generation = audience.generation

        #expect(audience.pause(first) == .unrelated)
        #expect(audience.served === second, "the other phone's picture does not blink")
        #expect(audience.generation == generation, "and nothing was rescheduled for it")
    }

    @Test("the capture stops only when the last client has asked for no frames")
    func captureStopsWhenTheLastClientPauses() {
        var audience = VideoAudience<Connection>()
        let first = Connection("phone-a")
        let second = Connection("phone-b")
        audience.connected(first, described: true)
        audience.pause(first)
        audience.connected(second, described: true)

        #expect(!audience.isIdle, "one client is still asking for frames")

        #expect(audience.pause(second) == .attached)
        #expect(audience.isIdle, "and now none of them is")
        #expect(audience.pausedConnections.count == 2, "both connections are still open")
    }

    @Test("a client that paused gets its own connection back")
    func resumedConnectionIsTakenOutOfThePausedList() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")
        audience.connected(phone, described: true)
        audience.pause(phone)

        let paused = audience.pausedConnections.first
        #expect(paused === phone, "which is what the caller looks up by client key")

        audience.connected(phone, described: true)

        #expect(audience.served === phone)
        #expect(audience.pausedConnections.isEmpty, "a connection that is back is not paused")
        #expect(!audience.isIdle)
    }

    @Test("a repeated pause changes nothing")
    func repeatedPauseIsStable() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")
        audience.connected(phone, described: true)
        audience.pause(phone)
        let generation = audience.generation

        #expect(audience.pause(phone) == .unrelated)
        #expect(audience.generation == generation)
        #expect(audience.pausedConnections.count == 1)
    }

    /// A paused connection closing is not an audience change: advancing the generation would discard a queued start for the client still watching.
    @Test("a connection that closes while paused is forgotten quietly")
    func closingAPausedConnectionDisturbsNothing() {
        var audience = VideoAudience<Connection>()
        let paused = Connection("phone-a")
        let watching = Connection("phone-b")
        audience.connected(paused, described: true)
        audience.pause(paused)
        audience.connected(watching, described: true)
        let generation = audience.generation

        #expect(audience.closed(paused) == .paused)
        #expect(audience.generation == generation)
        #expect(audience.served === watching)
        #expect(audience.pausedConnections.isEmpty)
    }

    @Test("closing the served connection empties the audience")
    func closingTheServedConnection() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")
        audience.connected(phone, described: true)

        #expect(audience.closed(phone) == .attached)
        #expect(audience.isIdle)
    }

    /// An unrelated close must not schedule a stop for the client being served.
    @Test("an unrelated close changes nothing")
    func unrelatedClose() {
        var audience = VideoAudience<Connection>()
        let phone = Connection("phone")
        let stranger = Connection("stranger")
        audience.connected(phone, described: true)
        let generation = audience.generation

        #expect(audience.closed(stranger) == .unrelated)
        #expect(audience.generation == generation)
        #expect(audience.served === phone)
    }

    @Test("the audience can be emptied completely")
    func removeAllForgetsEveryConnection() {
        var audience = VideoAudience<Connection>()
        let watching = Connection("phone-a")
        let paused = Connection("phone-b")
        audience.connected(watching, described: true)
        audience.connected(paused, described: true)
        audience.pause(paused)

        audience.removeAll()

        #expect(audience.isIdle)
        #expect(audience.served == nil)
        #expect(audience.pausedConnections.isEmpty)
    }
}
