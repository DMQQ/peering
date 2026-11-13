import Foundation

/// Addresses at which one end can be reached without the relay, besides the one the relay saw it at: a port its router opened for it on request. Each is `host:port`, an IPv4 literal.
public struct DirectCandidates: Codable, Sendable, Equatable {
    public var addresses: [String]

    public init(addresses: [String]) {
        self.addresses = addresses
    }

    /// Splits `host:port`, refusing anything else, so a malformed announcement is dropped rather than probed.
    public static func parse(_ address: String) -> (host: String, port: UInt16)? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        let host = String(address[..<colon])
        guard !host.isEmpty, let port = UInt16(address[address.index(after: colon)...]), port > 0 else { return nil }
        return (host, port)
    }

    /// Whether anyone on the internet can send to this IPv4 address. A router behind carrier-grade NAT reports a mapping in `100.64.0.0/10`, and a second router in front of it one in a private range: announcing either would send the client to an address that is not the Mac.
    public static func isPubliclyRoutable(ipv4 address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (224...255, _): return false
        case (100, 64...127): return false
        case (172, 16...31): return false
        default: return true
        }
    }
}
