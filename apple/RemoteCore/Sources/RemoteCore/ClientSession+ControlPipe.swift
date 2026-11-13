import Foundation

extension ClientSession {
    /// Lets the control connection's bytes cross the datagram lane while the direct path is live, and the relay's TCP connection otherwise.
    func attachControlPipe(to socket: VideoDatagramSocket) {
        guard let proxy = lock.withLock({ relayProxy }) else { return }
        proxy.attachDirect(
            send: { [weak self] frame in
                guard let self else { return }
                let sealed = self.lock.withLock { () -> [Data] in
                    var sealer = self.videoSealer
                    defer { self.videoSealer = sealer }
                    return sealer?.seal(kind: .controlPipe, payload: frame) ?? []
                }
                if !sealed.isEmpty { socket.sendDirect(sealed) { _ in } }
            },
            isLive: { [weak socket] in socket?.pathIsLive == true }
        )
    }
}
