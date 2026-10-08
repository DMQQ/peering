import Darwin
import Foundation

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
