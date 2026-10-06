// The hand-built datagram below is sealed with the opener's key: bytes that authenticate yet are not what a peer would send.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing

@testable import RemoteCore

private let sessionToken = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })

private func payload(bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

/// What the relay does between the two ends: strips the sender's token and forwards the rest. Written out because that contract lives in another repository.
private func forwarded(_ datagrams: [Data]) -> [Data] {
    datagrams.map { Data($0.dropFirst(VideoDatagram.tokenSize)) }
}

private func lane(
    secret: Data = payload(bytes: VideoKeySchedule.secretSize)
) -> (sealer: VideoDatagramSealer, opener: VideoDatagramOpener) {
    let schedule = VideoKeySchedule(secret: secret)
    return (
        try! schedule.sealer(token: sessionToken, direction: .hostToClient),
        schedule.opener(direction: .hostToClient)
    )
}

@Suite("The keys two ends seal video datagrams with")
struct VideoKeyScheduleTests {
    @Test("the two directions get different keys from one secret")
    func directionsAreSeparated() {
        let schedule = VideoKeySchedule(secret: payload(bytes: VideoKeySchedule.secretSize))

        let outbound = schedule.key(for: .hostToClient)
        let inbound = schedule.key(for: .clientToHost)

        // The counter is the nonce and travels in the clear, so two senders counting from one under one key would repeat a nonce.
        #expect(outbound != inbound)
        #expect(outbound.withUnsafeBytes { Data($0) }.count == VideoKeySchedule.secretSize)
    }

    @Test("the same secret and direction derive the same key on both ends")
    func derivationIsDeterministic() {
        let secret = payload(bytes: VideoKeySchedule.secretSize)

        #expect(
            VideoKeySchedule(secret: secret).key(for: .clientToHost)
                == VideoKeySchedule(secret: secret).key(for: .clientToHost)
        )
    }

    @Test("a different secret derives a different key")
    func secretsAreNotInterchangeable() {
        let one = VideoKeySchedule(secret: payload(bytes: 32))
        let two = VideoKeySchedule(secret: Data(payload(bytes: 32).reversed()))

        #expect(one.key(for: .hostToClient) != two.key(for: .hostToClient))
    }

    @Test("a secret is 32 random bytes, and no two are alike")
    func secretsAreRandom() throws {
        let first = try #require(VideoKeySchedule.randomSecret())
        let second = try #require(VideoKeySchedule.randomSecret())

        #expect(first.count == VideoKeySchedule.secretSize)
        #expect(first != second)
    }

    @Test("a token that is not the size the relay fixed it at is refused")
    func shortTokensAreRefused() {
        let schedule = VideoKeySchedule(secret: payload(bytes: 32))

        #expect(throws: VideoDatagramError.invalidToken(bytes: 8)) {
            _ = try schedule.sealer(token: Data(repeating: 0, count: 8), direction: .hostToClient)
        }
    }
}

@Suite("Sealing and opening video datagrams")
struct VideoDatagramRoundTripTests {
    @Test("a payload that fits one datagram makes the round trip byte for byte")
    func smallPayloadRoundTrips() throws {
        var (sealer, opener) = lane()

        let datagrams = sealer.seal(kind: .videoFrame, payload: payload(bytes: 600))
        #expect(datagrams.count == 1)

        let frame = try opener.open(try #require(forwarded(datagrams).first))
        #expect(frame?.kind == .videoFrame)
        #expect(frame?.payload == payload(bytes: 600))
    }

    @Test("a payload larger than a chunk is cut up and comes back whole")
    func largePayloadRoundTrips() throws {
        var (sealer, opener) = lane()

        let original = payload(bytes: 3000)
        let datagrams = forwarded(sealer.seal(kind: .videoFrame, payload: original))

        #expect(datagrams.count == 3)
        #expect(try opener.open(datagrams[0]) == nil)
        #expect(try opener.open(datagrams[1]) == nil)

        let frame = try opener.open(datagrams[2])
        #expect(frame?.kind == .videoFrame)
        #expect(frame?.payload == original)
    }

    @Test("chunks that arrive out of order still make the picture")
    func outOfOrderDeliveryIsAccepted() throws {
        var (sealer, opener) = lane()

        let original = payload(bytes: 3000)
        let datagrams = forwarded(sealer.seal(kind: .videoFrame, payload: original))
        #expect(datagrams.count == 3)

        // Reordering is the normal state of a datagram path; a receiver needing ascending counters would drop overtaken pictures.
        #expect(try opener.open(datagrams[2]) == nil)
        #expect(try opener.open(datagrams[0]) == nil)
        let frame = try opener.open(datagrams[1])

        #expect(frame?.payload == original)
    }

    @Test("every kind a frame can be travels a datagram")
    func otherKindsRoundTrip() throws {
        var (sealer, opener) = lane()

        let audio = payload(bytes: 320)
        let datagrams = forwarded(sealer.seal(kind: .audioFrame, payload: audio))
        let frame = try opener.open(try #require(datagrams.first))

        #expect(frame?.kind == .audioFrame)
        #expect(frame?.payload == audio)
    }

    @Test("a datagram is the token, then a counter in the clear, then the sealed bytes")
    func wireLayoutMatchesTheContract() throws {
        var (sealer, _) = lane()

        let datagrams = sealer.seal(kind: .videoFrame, payload: payload(bytes: 200))
        let datagram = try #require(datagrams.first)

        #expect(datagram.prefix(VideoDatagram.tokenSize) == sessionToken)
        #expect(
            datagram.count
                == VideoDatagram.tokenSize + VideoDatagram.counterSize + 5 + 200 + VideoDatagram.tagSize
        )
        #expect(datagram.readBigEndianUInt64(at: VideoDatagram.tokenSize) == 1)
    }

    @Test("counters ascend by one per datagram and never repeat")
    func countersAscend() throws {
        var (sealer, _) = lane()

        var counters: [UInt64] = []
        for _ in 0..<4 {
            counters += sealer.seal(kind: .videoFrame, payload: payload(bytes: 200)).map {
                $0.readBigEndianUInt64(at: VideoDatagram.tokenSize)
            }
        }
        counters += sealer.seal(kind: .videoFrame, payload: payload(bytes: 3000)).map {
            $0.readBigEndianUInt64(at: VideoDatagram.tokenSize)
        }

        #expect(counters == Array(1...UInt64(counters.count)))
    }

    @Test("a sealed datagram fits inside the smallest MTU anyone deploys")
    func datagramsStayUnderTheMTU() {
        var (sealer, _) = lane()

        // IPv6 guarantees 1280 bytes unfragmented; a full chunk of every kind must stay at or under that.
        let video = sealer.seal(kind: .videoFrame, payload: payload(bytes: 4096))
        let audio = sealer.seal(kind: .audioFrame, payload: payload(bytes: 4096))

        for datagram in video + audio {
            #expect(datagram.count <= 1280)
        }
    }
}

@Suite("What a datagram the receiver will not open does")
struct VideoDatagramFailureTests {
    @Test("a sealed datagram opened with the other direction's key does not authenticate")
    func directionsCannotOpenEachOther() throws {
        let secret = payload(bytes: VideoKeySchedule.secretSize)
        let schedule = VideoKeySchedule(secret: secret)
        var sealer = try schedule.sealer(token: sessionToken, direction: .hostToClient)
        var opener = schedule.opener(direction: .clientToHost)

        let datagrams = forwarded(sealer.seal(kind: .videoFrame, payload: payload(bytes: 200)))

        #expect(throws: VideoDatagramError.authenticationFailed) {
            _ = try opener.open(try #require(datagrams.first))
        }
    }

    @Test("a tampered datagram throws rather than being skipped")
    func tamperingIsReported() throws {
        var (sealer, opener) = lane()

        var datagram = try #require(forwarded(sealer.seal(kind: .videoFrame, payload: payload(bytes: 200))).first)
        datagram[20] ^= 0x01

        // Not `nil`: a datagram failing authentication is the only evidence of a key mismatch as opposed to a lossy network.
        #expect(throws: VideoDatagramError.authenticationFailed) {
            _ = try opener.open(datagram)
        }
    }

    @Test("a tampered tag throws, and a tampered counter throws")
    func theTagAndTheCounterAreBothCovered() throws {
        let datagrams = { () -> [Data] in
            var (sealer, _) = lane()
            return forwarded(sealer.seal(kind: .videoFrame, payload: payload(bytes: 200)))
        }()

        var badTag = try #require(datagrams.first)
        badTag[badTag.count - 1] ^= 0x80
        var (_, tagOpener) = lane()
        #expect(throws: VideoDatagramError.authenticationFailed) {
            _ = try tagOpener.open(badTag)
        }

        var movedCounter = try #require(datagrams.first)
        movedCounter[7] &+= 1
        var (_, counterOpener) = lane()
        #expect(throws: VideoDatagramError.authenticationFailed) {
            _ = try counterOpener.open(movedCounter)
        }
    }

    @Test("a datagram that did not authenticate does not move the replay window")
    func aForgedDatagramCannotBlindTheReceiver() throws {
        var (sealer, opener) = lane()

        let genuine = forwarded(sealer.seal(kind: .videoFrame, payload: payload(bytes: 200)))

        // A forged far-future counter must not advance the window on arrival, or one spoofed datagram would push out every genuine one.
        var forged = Data(repeating: 0, count: 64)
        forged.appendBigEndian(UInt64.max / 2)
        #expect(throws: VideoDatagramError.authenticationFailed) {
            _ = try opener.open(forged)
        }

        let frame = try opener.open(try #require(genuine.first))
        #expect(frame?.payload == payload(bytes: 200))
    }

    @Test("a datagram too short to hold a counter and a tag is refused")
    func truncatedDatagramsAreRefused() {
        var (_, opener) = lane()

        #expect(throws: VideoDatagramError.truncated(have: 12, need: VideoDatagram.minForwardedSize)) {
            _ = try opener.open(payload(bytes: 12))
        }
    }

    @Test("a datagram larger than this protocol ever sends is refused")
    func oversizedDatagramsAreRefused() {
        var (_, opener) = lane()

        #expect(throws: VideoDatagramError.oversized(bytes: VideoDatagram.maxDatagramSize + 1)) {
            _ = try opener.open(payload(bytes: VideoDatagram.maxDatagramSize + 1))
        }
    }

    @Test("bytes that authenticate but are not a frame are refused")
    func authenticatedGarbageIsRefused() throws {
        let schedule = VideoKeySchedule(secret: payload(bytes: VideoKeySchedule.secretSize))
        var opener = schedule.opener(direction: .hostToClient)

        let nonce = try #require(VideoDatagramSealer.nonce(1))
        let box = try ChaChaPoly.seal(
            Data([0x00, 0x00, 0x00, 0x02, 0x99, 0x00]),
            using: schedule.key(for: .hostToClient),
            nonce: nonce
        )
        var datagram = Data()
        datagram.appendBigEndian(UInt64(1))
        datagram.append(box.ciphertext)
        datagram.append(box.tag)

        #expect(throws: VideoDatagramError.malformedPayload) {
            _ = try opener.open(datagram)
        }
    }
}

@Suite("The window that decides which datagrams are too late")
struct VideoReplayWindowTests {
    @Test("a counter is accepted once and refused the second time")
    func duplicatesAreRefused() {
        var window = VideoReplayWindow()

        #expect(window.accepts(1))
        window.commit(1)
        #expect(!window.accepts(1))
    }

    @Test("a datagram that overtook its neighbours is accepted when it arrives")
    func reorderingIsAccepted() {
        var window = VideoReplayWindow()

        // Reordered, not replayed: the window must not drop these.
        for counter in UInt64(5)...9 { window.commit(counter) }

        for counter in UInt64(1)...4 {
            #expect(window.accepts(counter))
            window.commit(counter)
        }
        for counter in UInt64(1)...9 {
            #expect(!window.accepts(counter))
        }
    }

    @Test("a counter older than the window is refused, and one at its edge is not")
    func theWindowHasAnEdge() {
        var window = VideoReplayWindow()
        window.commit(1000)

        #expect(window.accepts(1000 - UInt64(VideoReplayWindow.size) + 1))
        #expect(!window.accepts(1000 - UInt64(VideoReplayWindow.size)))
        #expect(!window.accepts(1))
    }

    @Test("a jump wider than the window does not remember the counters it skipped")
    func aLargeJumpEmptiesTheWindow() {
        var window = VideoReplayWindow()

        window.commit(1)
        window.commit(1_000_000)
        #expect(!window.accepts(1))
        #expect(window.accepts(1_000_000) == false)
        #expect(window.accepts(999_999))
    }

    @Test("forgetting starts the window over")
    func resetClearsEverything() {
        var window = VideoReplayWindow()
        window.commit(7)
        #expect(!window.accepts(7))

        window.reset()

        #expect(window.accepts(7))
        #expect(window.accepts(1))
    }
}

@Suite("A picture that arrives with pieces missing")
struct VideoDatagramLossTests {
    @Test("a lost chunk costs one picture and never wedges the stream")
    func aLostChunkIsNotFatal() throws {
        var (sealer, opener) = lane()

        let lost = forwarded(sealer.seal(kind: .videoFrame, payload: payload(bytes: 3000)))
        #expect(lost.count == 3)

        #expect(try opener.open(lost[0]) == nil)
        #expect(try opener.open(lost[2]) == nil)

        let next = payload(bytes: 2500)
        var last: Frame?
        for datagram in forwarded(sealer.seal(kind: .videoFrame, payload: next)) {
            last = try opener.open(datagram) ?? last
        }
        #expect(last?.payload == next)
    }

    @Test("a piece that arrives twice is not appended twice")
    func duplicatesDoNotCorruptThePicture() throws {
        var (sealer, opener) = lane()

        let original = payload(bytes: 3000)
        let datagrams = forwarded(sealer.seal(kind: .videoFrame, payload: original))

        #expect(try opener.open(datagrams[0]) == nil)
        #expect(try opener.open(datagrams[0]) == nil)
        #expect(try opener.open(datagrams[1]) == nil)
        let frame = try opener.open(datagrams[2])

        #expect(frame?.payload == original)
    }

    @Test("the first picture of a session is assembled from nothing")
    func theFirstPictureIsNotSpecial() throws {
        var (sealer, opener) = lane()

        let original = payload(bytes: 2500)
        var last: Frame?
        for datagram in forwarded(sealer.seal(kind: .audioFrame, payload: original)) {
            last = try opener.open(datagram) ?? last
        }

        #expect(last?.kind == .audioFrame)
        #expect(last?.payload == original)
    }
}

@Suite("What the two message kinds say on the wire")
struct VideoKeyMessageTests {
    @Test("the key exchange has kinds of its own, above the fallback's")
    func messageKindsAreStable() {
        // Fixed values rather than `allCases`: another repository's relay holds these numbers too.
        #expect(MessageKind.videoKeyRequest.rawValue == 0x19)
        #expect(MessageKind.videoKey.rawValue == 0x1A)
        #expect(MessageKind.allCases.contains(.videoKeyRequest))
        #expect(MessageKind.allCases.contains(.videoKey))
    }

    @Test("a grant carries the secret byte for byte")
    func grantsRoundTrip() throws {
        let secret = payload(bytes: VideoKeySchedule.secretSize)

        let encoded = try MessageCodec.encode(VideoKeyGrant(secret: secret))
        let decoded = try MessageCodec.decode(VideoKeyGrant.self, from: encoded)

        #expect(decoded.secret == secret)
    }

    /// A mixed pair must fail at the door, so the version is read back and a bump has to be deliberate.
    @Test("the two ends of the exchange agree about the protocol version")
    func theVersionWasBumped() {
        #expect(ProtocolInfo.version == 20)
    }
}
