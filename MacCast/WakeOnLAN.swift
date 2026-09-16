import Foundation
import Network

/// Sends an IEEE 802 Wake-on-LAN magic packet to a single hardware MAC address.
///
/// The packet is a 6-byte broadcast header (0xFF×6) followed by the target MAC repeated
/// 16 times — 102 bytes total. Sent as a UDP broadcast on port 9 (the discard port, which
/// is what routers expect) and also port 7 as a fallback.
enum WakeOnLAN {
    /// Parses a colon-separated MAC address string and sends the magic packet.
    /// Silently does nothing on a malformed address.
    static func send(to macString: String) {
        let fields = macString.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 6,
              fields.allSatisfy({ $0.count == 2 }),
              fields.allSatisfy({ $0.allSatisfy(\.isHexDigit) })
        else { return }
        let bytes = fields.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        send(mac: bytes)
    }

    private static func send(mac: [UInt8]) {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        sendUDP(packet, port: 9)
        sendUDP(packet, port: 7)
    }

    private static func sendUDP(_ data: Data, port: UInt16) {
        let connection = NWConnection(
            host: .ipv4(.broadcast),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                })
            case .failed:
                connection.stateUpdateHandler = nil
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }
}
