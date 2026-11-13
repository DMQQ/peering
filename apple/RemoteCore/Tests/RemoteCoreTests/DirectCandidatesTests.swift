import Foundation
import Testing

@testable import RemoteCore

@Suite("Direct candidates")
struct DirectCandidatesTests {
    @Test("host and port are split at the last colon")
    func parses() {
        let parsed = DirectCandidates.parse("203.0.113.7:51234")
        #expect(parsed?.host == "203.0.113.7")
        #expect(parsed?.port == 51234)
    }

    @Test("an address with no port, an empty host or a zero port is refused")
    func refusesMalformed() {
        #expect(DirectCandidates.parse("203.0.113.7") == nil)
        #expect(DirectCandidates.parse(":5000") == nil)
        #expect(DirectCandidates.parse("203.0.113.7:0") == nil)
        #expect(DirectCandidates.parse("203.0.113.7:99999") == nil)
    }

    @Test("an announcement survives the wire")
    func roundTrips() throws {
        let sent = DirectCandidates(addresses: ["203.0.113.7:51234"])
        let decoded = try MessageCodec.decode(DirectCandidates.self, from: try MessageCodec.encode(sent))
        #expect(decoded == sent)
    }

    @Test("a client says it understands announcements, and one from before the field says nothing")
    func helloFlag() throws {
        let hello = ClientHello(clientID: "c", clientName: "n", protocolVersion: 1, wantsPairing: false, supportsDirectCandidates: true)
        let decoded = try MessageCodec.decode(ClientHello.self, from: try MessageCodec.encode(hello))
        #expect(decoded.supportsDirectCandidates == true)
        let older = ClientHello(clientID: "c", clientName: "n", protocolVersion: 1, wantsPairing: false)
        #expect(older.supportsDirectCandidates == nil)
    }

    @Test("private, shared, loopback, link-local and multicast addresses are not announced")
    func refusesUnroutable() {
        for address in ["10.0.0.5", "172.16.0.1", "172.31.255.1", "192.168.1.20", "100.64.0.1", "100.127.1.1", "127.0.0.1", "169.254.1.1", "224.0.0.1", "0.0.0.0", "not an address"] {
            #expect(!DirectCandidates.isPubliclyRoutable(ipv4: address), "\(address)")
        }
    }

    @Test("a public address is announced, including ones next to a private range")
    func acceptsRoutable() {
        for address in ["203.0.113.7", "8.8.8.8", "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.169.0.1"] {
            #expect(DirectCandidates.isPubliclyRoutable(ipv4: address), "\(address)")
        }
    }
}
