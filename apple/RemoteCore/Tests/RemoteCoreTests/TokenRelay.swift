import Darwin
import Foundation

/// The relay's UDP forwarding in miniature: the first byte of the 16-byte token says which end sent it, the token is stripped, and the rest goes to the other end's last address.
final class TokenRelay: @unchecked Sendable {
    static func token(_ side: UInt8) -> Data { Data([side] + [UInt8](repeating: 0xEE, count: 15)) }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var ends: [UInt8: sockaddr_in] = [:]
    private var _forwarded = 0
    private var running = true
    var forwarded: Int { lock.withLock { _forwarded } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = descriptor
        Thread.detachNewThread { [self] in loop() }
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while lock.withLock({ running }) {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let read = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard read >= 16 else { continue }
            let side = buffer[0]
            let other = lock.withLock { () -> sockaddr_in? in
                ends[side] = from
                return ends[side == 0 ? 1 : 0]
            }
            guard read > 16, var destination = other else { continue }
            _ = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, Array(buffer[16..<read]), read - 16, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            lock.withLock { _forwarded += 1 }
        }
        close(fd)
    }

    func stop() { lock.withLock { running = false } }
}
