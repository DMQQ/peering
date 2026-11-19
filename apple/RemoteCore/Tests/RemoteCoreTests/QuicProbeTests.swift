import Foundation
import Testing

@testable import RemoteCore

extension ClientPairingTests {
    /// Nested so the parent's `.serialized` covers the Keychain keys these mint.
    @Suite("QUIC between two keychain identities")
    struct QuicProbeTests {
        @Test("the phone's probe completes a handshake, round trips and a datagram burst against the Mac's echo server")
        func probeAgainstEchoServer() async throws {
            try await withTestEnds { client, mac in
                let server = try QuicEchoServer(identity: mac, port: 0)
                defer { server.stop() }
                let report = await QuicProbe.run(host: "127.0.0.1", port: server.listeningPort, identity: client)
                let text = report.lines.joined(separator: "\n")
                #expect(text.contains("handshake"), "\(text)")
                #expect(text.contains("certificate: \(mac.certificateDER.count) bytes"), "\(text)")
                #expect(text.contains("stream round trip"), "\(text)")
                #expect(text.contains("arrived"), "\(text)")
                #expect(!text.contains("unanswered"), "\(text)")
            }
        }
    }
}
