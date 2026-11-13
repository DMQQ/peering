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

    @Test("a router's answer becomes the host and port in the right byte order")
    func mappedCandidateOrdersBytes() {
        // 203.0.113.7 as the system hands it over: network byte order, so the first octet is the lowest byte.
        let address = UInt32(203) | UInt32(0) << 8 | UInt32(113) << 16 | UInt32(7) << 24
        let candidate = DirectCandidates.mappedCandidate(errorCode: 0, externalAddress: address, externalPort: UInt16(51234).bigEndian)
        #expect(candidate == "203.0.113.7:51234")
    }

    @Test("an error, a zero address or a zero port from the router announces nothing")
    func mappedCandidateRefusesIncompleteAnswers() {
        let address = UInt32(203) | UInt32(113) << 16 | UInt32(7) << 24
        #expect(DirectCandidates.mappedCandidate(errorCode: -65_563, externalAddress: address, externalPort: UInt16(5000).bigEndian) == nil)
        #expect(DirectCandidates.mappedCandidate(errorCode: 0, externalAddress: 0, externalPort: UInt16(5000).bigEndian) == nil)
        #expect(DirectCandidates.mappedCandidate(errorCode: 0, externalAddress: address, externalPort: 0) == nil)
    }

    @Test("a router behind another NAT announces nothing, because its address is not the internet's")
    func mappedCandidateRefusesPrivateAddress() {
        let carrierGrade = UInt32(100) | UInt32(64) << 8 | UInt32(0) << 16 | UInt32(1) << 24
        #expect(DirectCandidates.mappedCandidate(errorCode: 0, externalAddress: carrierGrade, externalPort: UInt16(5000).bigEndian) == nil)
    }

    @Test("an announcement yields every address that parses and skips the rest")
    func targetsSkipBadAddresses() throws {
        let payload = try MessageCodec.encode(DirectCandidates(addresses: ["203.0.113.7:5000", "garbage", "198.51.100.2:6000", "host:0"]))
        let targets = DirectCandidates.targets(in: payload)
        #expect(targets.map(\.host) == ["203.0.113.7", "198.51.100.2"])
        #expect(targets.map(\.port) == [5000, 6000])
    }

    @Test("a payload that is not an announcement yields no targets")
    func targetsOfNonsense() {
        #expect(DirectCandidates.targets(in: Data([0x00, 0x01, 0x02])).isEmpty)
        #expect(DirectCandidates.targets(in: Data()).isEmpty)
    }

    @Test("the Mac announces once the router has answered, and stops once the path is open")
    func announcement() {
        #expect(DirectCandidates.announcement(mapped: nil, pathIsOpen: false) == nil)
        #expect(DirectCandidates.announcement(mapped: "203.0.113.7:5000", pathIsOpen: false)?.addresses == ["203.0.113.7:5000"])
        #expect(DirectCandidates.announcement(mapped: "203.0.113.7:5000", pathIsOpen: true) == nil)
    }
}
