import Foundation

/// This Mac's own IPv4 address on the local network, for the person who has to type it into the
/// iPhone by hand because discovery did not find this Mac. `en0` first, since that is Wi-Fi on
/// every Mac this app runs on and the interface a phone on the same network actually shares.
func localIPv4Address() -> String? {
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
    defer { freeifaddrs(ifaddrPointer) }

    var fallback: String?
    for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let flags = Int32(cursor.pointee.ifa_flags)
        guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
              cursor.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        let name = String(cString: cursor.pointee.ifa_name)
        var address = sockaddr_in()
        memcpy(&address, cursor.pointee.ifa_addr, MemoryLayout<sockaddr_in>.size)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: buffer)

        if name == "en0" { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}
