import Darwin
import Foundation

/// Reads the hardware MAC addresses of physical network interfaces.
enum NetworkInterfaceInfo {
    /// Returns colon-separated MAC address strings (e.g. "aa:bb:cc:dd:ee:ff") for all
    /// physical interfaces that carry a 6-byte link-level address.
    static func hardwareMACAddresses() -> [String] {
        var result: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let start = ifaddrPtr else { return [] }
        defer { freeifaddrs(start) }

        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8

        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            guard iface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }

            iface.pointee.ifa_addr?.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                let nameLength = Int(sdl.pointee.sdl_nlen)
                let addressLength = Int(sdl.pointee.sdl_alen)
                guard addressLength == 6 else { return }

                // Read through the pointer, not out of `sdl_data`.
                //
                // `sdl_data` is *declared* as 12 bytes and is not: it is the first 12 bytes of a
                // variable-length tail, and the kernel writes the whole interface name into it
                // however long that name is. A name of 7 characters — `bridge0` is one, and this
                // Mac has had one — puts the address at offset 13, and indexing the declared
                // array for it is an out-of-bounds read that Swift traps on rather than
                // returning garbage. It is a crash, not a wrong answer, and it happened on every
                // connection from a paired device, because that is when the server hello carries
                // these for Wake-on-LAN.
                //
                // So: the address is contiguous in the buffer `getifaddrs` handed us, at the
                // declared offset plus the name, and `sdl_len` is the length the kernel records
                // for the whole structure — which is the bound that makes this safe rather than
                // merely different.
                let totalLength = Int(sdl.pointee.sdl_len)
                guard totalLength >= dataOffset + nameLength + addressLength else { return }

                let address = UnsafeRawPointer(sdl)
                    .advanced(by: dataOffset + nameLength)
                    .assumingMemoryBound(to: UInt8.self)
                let macBytes = Array(UnsafeBufferPointer(start: address, count: addressLength))
                guard macBytes.contains(where: { $0 != 0 }) else { return }
                result.append(macBytes.map { String(format: "%02x", $0) }.joined(separator: ":"))
            }
        }
        return result
    }
}
