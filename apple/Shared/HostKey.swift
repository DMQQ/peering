import CryptoKit
import Foundation

/// A short stable id for a Mac that can ride in a push without being the Mac's real id: the app and the widget know the real one and compute the same key.
nonisolated enum HostKey {
    static func of(_ hostID: String) -> String {
        SHA256.hash(data: Data(hostID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
