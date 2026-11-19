import Darwin
import Foundation

/// A socket address in the form quiche and the BSD socket calls both take.
public struct QuicAddress: Sendable, Equatable, CustomStringConvertible {
    var storage: sockaddr_storage
    var length: socklen_t

    init(storage: sockaddr_storage, length: socklen_t) {
        self.storage = storage
        self.length = length
    }

    /// A numeric IPv4 or IPv6 address. IPv4 is written as v4-mapped IPv6, because every Peering QUIC socket is a dual-stack IPv6 one.
    public init?(host: String, port: UInt16) {
        var storage = sockaddr_storage()
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = port.bigEndian
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let mapped = "::ffff:" + host
            guard inet_pton(AF_INET6, mapped, &v6.sin6_addr) == 1 else { return nil }
        } else if inet_pton(AF_INET6, host, &v6.sin6_addr) != 1 {
            return nil
        }
        withUnsafeMutableBytes(of: &storage) { raw in
            withUnsafeBytes(of: v6) { raw.copyMemory(from: $0) }
        }
        self.init(storage: storage, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    /// Resolves a name, IPv4 answers as v4-mapped IPv6 to suit the dual-stack socket: asking for AF_INET6 alone refuses an A-only name, and a plain v4 answer cannot be sent from a v6 socket.
    public static func resolve(host: String, port: UInt16) -> QuicAddress? {
        if let numeric = QuicAddress(host: host, port: port) { return numeric }
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_V4MAPPED | AI_ALL
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(first.pointee.ai_addrlen)))
        }
        return QuicAddress(storage: storage, length: first.pointee.ai_addrlen)
    }

    func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result) rethrows -> Result {
        try withUnsafePointer(to: storage) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    public var port: UInt16 {
        withSockaddr { pointer, _ -> UInt16 in
            switch Int32(pointer.pointee.sa_family) {
            case AF_INET6: return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            case AF_INET: return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            default: return 0
            }
        }
    }

    /// The numeric host alone, without the port.
    public var hostText: String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let found = withSockaddr { pointer, length in
            getnameinfo(pointer, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        }
        guard found else { return "unknown" }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var description: String { "[\(hostText)]:\(port)" }

    public static func == (lhs: QuicAddress, rhs: QuicAddress) -> Bool {
        guard lhs.length == rhs.length else { return false }
        return withUnsafeBytes(of: lhs.storage) { left in
            withUnsafeBytes(of: rhs.storage) { right in
                left.prefix(Int(lhs.length)).elementsEqual(right.prefix(Int(rhs.length)))
            }
        }
    }
}
