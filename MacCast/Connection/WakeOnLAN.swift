import Foundation
import Network

/// Sends a Wake-on-LAN magic packet (0xFF x6, then the MAC x16) as a UDP broadcast on port 9, and port 7 as a fallback.
enum WakeOnLAN {
    @discardableResult
    static func send(to macString: String) -> Bool {
        let fields = macString.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 6,
              fields.allSatisfy({ $0.count == 2 }),
              fields.allSatisfy({ $0.allSatisfy(\.isHexDigit) })
        else { return false }
        let bytes = fields.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        send(mac: bytes)
        return true
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
