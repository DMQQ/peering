import Foundation
import RemoteCore
import os

/// The QUIC spike's Mac end: an echo server the phone's Developer › QUIC test measures against. Off unless `defaults write <host bundle id> quicSpike -bool YES`, because the host is installed as a Release build; not part of any session.
enum QuicSpike {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var server: QuicEchoServer?

    static func start(identity: SelfSignedIdentity) {
        lock.withLock {
            guard server == nil, UserDefaults.standard.bool(forKey: "quicSpike") else { return }
            do {
                server = try QuicEchoServer(identity: identity)
            } catch {
                Logger(subsystem: "pl.dmq.peering.host", category: "quic").error("the QUIC echo server could not start: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
