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

    /// The `host:port` to announce for what the router answered a mapping request with, or `nil` when there is nothing worth announcing. `externalAddress` and `externalPort` are in network byte order, as the system hands them over.
    public static func mappedCandidate(errorCode: Int32, externalAddress: UInt32, externalPort: UInt16) -> String? {
        guard errorCode == 0, externalAddress != 0, externalPort != 0 else { return nil }
        var raw = in_addr(s_addr: externalAddress)
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil else { return nil }
        let host = String(cString: text)
        guard isPubliclyRoutable(ipv4: host) else { return nil }
        return "\(host):\(UInt16(bigEndian: externalPort))"
    }

    /// The addresses in an announcement worth probing. A payload that does not decode gives none, and an address that does not parse is skipped without discarding the others.
    public static func targets(in payload: Data) -> [(host: String, port: UInt16)] {
        guard let announced = try? MessageCodec.decode(DirectCandidates.self, from: payload) else { return [] }
        return announced.addresses.compactMap(parse)
    }

    /// What the Mac announces now: nothing until the router has answered, and nothing once the direct path is open, since the client has found it.
    public static func announcement(mapped: String?, pathIsOpen: Bool) -> DirectCandidates? {
        guard let mapped, !pathIsOpen else { return nil }
        return DirectCandidates(addresses: [mapped])
    }
}
