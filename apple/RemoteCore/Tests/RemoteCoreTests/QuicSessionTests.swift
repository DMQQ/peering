import Foundation
import Security
import Testing

@testable import RemoteCore

/// Two ``QuicSession``s joined by an in-memory network that can lose packets and change addresses. No sockets: packets are moved by hand, which is what makes loss and migration repeatable.
private final class SimulatedNetwork {
    let phone: QuicSession
    var mac: QuicSession?
    private let macConfiguration: QuicConfiguration
    /// Where the phone's packets appear to come from; changing it is a NAT rebinding or a new network.
    var phoneAddress = QuicAddress(host: "10.0.0.2", port: 40_000)!
    let relayAddress = QuicAddress(host: "203.0.113.1", port: 20_190)!
    let directAddress = QuicAddress(host: "198.51.100.7", port: 51_517)!
    var lossEvery: Int?
    private var sentCount = 0
    var arrived: (phone: [Frame], mac: [Frame]) = ([], [])
    private(set) var lastPhoneDestination: QuicAddress?

    init(phone: QuicConfiguration, mac: QuicConfiguration) throws {
        let connection = try QuicConnection.connect(local: QuicAddress(host: "10.0.0.2", port: 40_000)!, peer: relayAddress, configuration: phone)
        self.phone = QuicSession(connection: connection, isClient: true)
        macConfiguration = mac
    }

    private func dropsThis() -> Bool {
        sentCount += 1
        guard let lossEvery else { return false }
        return sentCount % lossEvery == 0
    }

    /// One round: the phone's packets to the Mac, then the Mac's back, then any timers that are due.
    func step() throws {
        phone.writeUnsent()
        for packet in phone.connection.outgoing() where !dropsThis() {
            lastPhoneDestination = packet.destination
            if mac == nil {
                mac = QuicSession(connection: try QuicConnection.accept(local: packet.destination, peer: phoneAddress, configuration: macConfiguration), isClient: false)
            }
            mac?.connection.receive(packet.bytes, from: phoneAddress, to: packet.destination)
        }
        if let mac {
            arrived.mac += try mac.takeFrames()
            mac.writeUnsent()
            for packet in mac.connection.outgoing() where !dropsThis() {
                phone.connection.receive(packet.bytes, from: macSourceAddress(for: packet.destination), to: packet.destination)
            }
        }
        arrived.phone += try phone.takeFrames()
        for connection in [phone.connection, mac?.connection].compactMap({ $0 }) {
            if let timeout = connection.timeout, timeout <= .milliseconds(1) { connection.onTimeout() }
        }
    }

    /// The Mac answers from whichever of its addresses the phone used last: the relay unless the phone has moved to the direct one.
    var macAnswersFrom: QuicAddress?
    private func macSourceAddress(for _: QuicAddress) -> QuicAddress { macAnswersFrom ?? relayAddress }

    func run(until done: () -> Bool, within seconds: Double = 5) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return }
            try step()
        }
    }

    func establish() throws {
        try run(until: { phone.connection.isEstablished && mac?.connection.isEstablished == true })
        // Both ends' first takeFrames after the handshake hands out spare ids; one more round delivers them.
        try step()
        try step()
    }
}

extension ClientPairingTests {
    /// Nested so the parent's `.serialized` covers the Keychain keys these mint.
    @Suite("Peering frames over one QUIC connection")
    struct QuicSessionTests {
        private func withNetwork(_ body: (SimulatedNetwork, SelfSignedIdentity, SelfSignedIdentity) throws -> Void) async throws {
            try await withTestEnds { client, mac in
                let network = try SimulatedNetwork(phone: QuicConfiguration(identity: client), mac: QuicConfiguration(identity: mac))
                try network.establish()
                try body(network, client, mac)
            }
        }

        private static func pin(of identity: SelfSignedIdentity) -> Data? {
            SecCertificateCreateWithData(nil, identity.certificateDER as CFData).flatMap(SPKI.bytes(of:))
        }

        @Test("each end learns the other's key in the form its pins are stored in")
        func peersPresentTheirPinnedKeys() async throws {
            try await withNetwork { network, client, mac in
                #expect(network.phone.peerPublicKey == Self.pin(of: mac))
                #expect(network.mac?.peerPublicKey == Self.pin(of: client))
            }
        }

        @Test("frames of every class arrive whole and in order, both ways")
        func framesArriveInOrder() async throws {
            try await withNetwork { network, _, _ in
                let sent = (0..<30).map { index -> Frame in
                    let kinds: [MessageKind] = [.command, .ping, .terminalRequest, .agentRequest, .clipboardContent]
                    return Frame(kind: kinds[index % kinds.count], payload: Data("frame \(index)".utf8))
                }
                for frame in sent { network.phone.send(frame) }
                network.mac?.send(Frame(kind: .pong, payload: Data("back".utf8)))
                try network.run(until: { network.arrived.mac.count == sent.count && network.arrived.phone.count == 1 })

                for kind in Set(sent.map(\.kind)) {
                    #expect(network.arrived.mac.filter { $0.kind == kind } == sent.filter { $0.kind == kind }, "\(kind)")
                }
                #expect(network.arrived.phone == [Frame(kind: .pong, payload: Data("back".utf8))])
            }
        }

        @Test("a picture larger than a datagram is cut, carried as datagrams and put back together")
        func aLargePictureTravelsAsDatagrams() async throws {
            try await withNetwork { network, _, _ in
                let picture = Frame(kind: .videoFrame, payload: Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
                network.mac?.send(picture)
                try network.run(until: { !network.arrived.phone.isEmpty })
                #expect(network.arrived.phone == [picture])
            }
        }

        @Test("a large file transfer does not hold back a command sent after it")
        func aTransferDoesNotDelayACommand() async throws {
            try await withNetwork { network, _, _ in
                let chunk = Data(#"{"writeChunk":{"bytes":""#.utf8) + Data(repeating: 0x41, count: 60_000) + Data(#""}}"#.utf8)
                for _ in 0..<60 { network.phone.send(Frame(kind: .terminalRequest, payload: chunk)) }
                let command = Frame(kind: .command, payload: Data("click".utf8))
                network.phone.send(command)
                try network.run(until: { network.arrived.mac.contains(command) })
                let transferDone = network.arrived.mac.filter { $0.kind == .terminalRequest }.count
                #expect(network.arrived.mac.contains(command))
                #expect(transferDone < 60, "the command arrived after \(transferDone) of 60 transfer chunks")
            }
        }

        @Test("every frame still arrives in order when one packet in seven is lost")
        func lossIsRepaired() async throws {
            try await withNetwork { network, _, _ in
                network.lossEvery = 7
                let sent = (0..<200).map { Frame(kind: .terminalEvent, payload: Data("line \($0)".utf8)) }
                for frame in sent { network.phone.send(frame) }
                try network.run(until: { network.arrived.mac.count == sent.count }, within: 20)
                #expect(network.arrived.mac == sent)
            }
        }

        @Test("a new address for the phone keeps the session: no new handshake, frames keep flowing")
        func aNetworkChangeKeepsTheSession() async throws {
            try await withNetwork { network, _, _ in
                network.phoneAddress = QuicAddress(host: "172.16.5.9", port: 61_000)!
                let after = Frame(kind: .command, payload: Data("after the change".utf8))
                network.phone.send(after)
                try network.run(until: { network.arrived.mac.contains(after) })
                #expect(network.arrived.mac.contains(after))
                network.mac?.send(Frame(kind: .pong))
                try network.run(until: { network.arrived.phone.contains(Frame(kind: .pong)) })
                #expect(network.arrived.phone.contains(Frame(kind: .pong)))
            }
        }

        @Test("the phone moves from the relay to the Mac's direct address once that path validates")
        func movesFromRelayToDirect() async throws {
            try await withNetwork { network, _, _ in
                let local = QuicAddress(host: "10.0.0.2", port: 40_000)!
                #expect(network.phone.connection.probePath(local: local, peer: network.directAddress))
                network.macAnswersFrom = network.directAddress
                try network.run(until: { network.phone.connection.isPathValidated(local: local, peer: network.directAddress) })
                #expect(network.phone.connection.isPathValidated(local: local, peer: network.directAddress))
                #expect(network.phone.connection.migrate(local: local, peer: network.directAddress))

                let after = Frame(kind: .command, payload: Data("direct".utf8))
                network.phone.send(after)
                try network.run(until: { network.arrived.mac.contains(after) })
                #expect(network.arrived.mac.contains(after))
                #expect(network.lastPhoneDestination == network.directAddress)
            }
        }
    }
}
