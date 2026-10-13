import CryptoKit
import Crypto
import Foundation
import Network
import Security

extension VideoDatagramSocket {
    /// Only the port and the address are compared, not the whole structure: the kernel writes a
    /// length and padding into the storage that a resolved address does not carry, so a
    /// byte-for-byte comparison would call the peer a stranger every time.
    static func sameAddress(_ lhs: sockaddr_storage, _ rhs: sockaddr_storage?) -> Bool {
        guard let rhs, lhs.ss_family == rhs.ss_family else { return false }

        return withUnsafeBytes(of: lhs) { left in
            withUnsafeBytes(of: rhs) { right in
                let leftPort = left.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                let rightPort = right.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
                guard leftPort == rightPort else { return false }

                switch Int32(lhs.ss_family) {
                case AF_INET:
                    return left.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                        == right.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                case AF_INET6:
                    return left.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                        == right.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                        && left.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                            == right.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                default:
                    return false
                }
            }
        }
    }

    /// `NI_NUMERICHOST`, so an address goes back out exactly as it came in and no name is ever
    /// looked up on a value that arrived over the network.
    static func describe(
        _ address: sockaddr_storage,
        length: socklen_t
    ) -> (host: String, port: UInt16)? {
        var storage = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))

        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0, length,
                    &host, socklen_t(host.count),
                    &service, socklen_t(service.count),
                    NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }
        guard result == 0 else { return nil }
        func decoded(_ buffer: [CChar]) -> String {
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (decoded(host), UInt16(decoded(service)) ?? 0)
    }

    /// macOS resolves an IPv4-only name asked for under `AF_INET6` to its v4-mapped form, so a socket
    /// aimed at a relay with an `A` record and no `AAAA` is built in `AF_INET6`, while the relay names
    /// the peer in `AF_INET`. `getaddrinfo` refuses a plain IPv4 literal for an `AF_INET6` socket, so
    /// the peer is spelled as `::ffff:` plus the literal. Fold on the way out, map on the way in.
    static func resolvePeer(
        host: String,
        port: UInt16,
        family: Int32
    ) -> (address: sockaddr_storage, length: socklen_t)? {
        if let resolved = resolve(host: host, port: port, family: family, numeric: true) {
            return resolved
        }
        guard family == AF_INET6 else { return nil }
        // On an IPv6-only network (NAT64, which App Review uses) a v4 literal has to go through the
        // resolver to be synthesised into a routable v6 address; `::ffff:` goes nowhere there.
        // Checked as a literal first, so a name from the relay still never reaches the resolver.
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1,
           let synthesised = resolve(host: host, port: port, family: AF_INET6, numeric: false, flags: AI_DEFAULT) {
            return synthesised
        }
        return resolve(host: "::ffff:\(host)", port: port, family: AF_INET6, numeric: true)
    }

    /// Asked one after the other, a slow resolver on cellular made the two waits add up. IPv6 is
    /// still preferred: an IPv4 answer is held for ``ipv6Preference`` in case IPv6 is about to land.
    /// The losing lookup is left to finish on its own thread and its answer is dropped.
    static func resolveRacing(
        host: String,
        port: UInt16
    ) -> (address: sockaddr_storage, length: socklen_t)? {
        typealias Answer = (address: sockaddr_storage, length: socklen_t)
        final class Race: @unchecked Sendable {
            let lock = NSLock()
            let done = DispatchSemaphore(value: 0)
            var v6: Answer?
            var v4: Answer?
            var finished = 0
        }
        let race = Race()
        for family in [AF_INET6, AF_INET] {
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = resolve(host: host, port: port, family: family, numeric: false)
                race.lock.withLock {
                    if family == AF_INET6 { race.v6 = answer } else { race.v4 = answer }
                    race.finished += 1
                }
                race.done.signal()
            }
        }

        var deadline: DispatchTime = .distantFuture
        while true {
            if race.done.wait(timeout: deadline) == .timedOut {
                return race.lock.withLock { race.v6 ?? race.v4 }
            }
            let (v6, v4, finished) = race.lock.withLock { (race.v6, race.v4, race.finished) }
            if let v6 { return v6 }
            if finished == 2 { return v4 }
            if v4 != nil, deadline == .distantFuture {
                deadline = .now() + ipv6Preference
            }
        }
    }

    static let ipv6Preference: DispatchTimeInterval = .milliseconds(50)

    /// `numeric` is for the peer, which the relay hands over as a literal: a name arriving from a
    /// server and going into a resolver is how a signalling service points a session where it likes.
    static func resolve(
        host: String,
        port: UInt16,
        family: Int32,
        numeric: Bool,
        flags: Int32 = 0
    ) -> (address: sockaddr_storage, length: socklen_t)? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = flags
        if numeric { hints.ai_flags |= AI_NUMERICHOST }

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return nil
        }
        defer { freeaddrinfo(info) }
        guard let addr = first.pointee.ai_addr, first.pointee.ai_addrlen > 0 else { return nil }

        var storage = sockaddr_storage()
        memcpy(&storage, addr, Int(first.pointee.ai_addrlen))
        return (storage, first.pointee.ai_addrlen)
    }

    /// The wildcard address for a family, so the kernel picks the port: whatever it hands back is
    /// what the NAT builds a mapping for, so a port chosen here would have no relationship to the
    /// address the direct path depends on.
    static func wildcard(family: Int32, into storage: inout sockaddr_storage) -> socklen_t {
        switch family {
        case AF_INET6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            address.sin6_addr = in6addr_any
            memcpy(&storage, &address, MemoryLayout<sockaddr_in6>.size)
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            memcpy(&storage, &address, MemoryLayout<sockaddr_in>.size)
            return socklen_t(MemoryLayout<sockaddr_in>.size)
        }
    }
}
