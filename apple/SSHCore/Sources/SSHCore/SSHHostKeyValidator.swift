import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

/// A struct rather than a closure because the three outcomes differ: a known key succeeds silently, a changed key fails outright, and a new one suspends the handshake on a human. `validateHostKey` runs on NIO's event loop and must answer through a promise, so the asking happens in a `Task` and the server waits mid-handshake, before anything assumes a trusted peer.
struct SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let endpoint: SSHEndpoint
    let store: SSHKnownHosts
    let ask: @Sendable (SSHHostKeyPrompt) async -> Bool
    let record: @Sendable (SSHHostKeyPrompt, Data) -> Void

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // The blob is what OpenSSH hashes and `write(to:)` is the only byte-exact way to get it; deriving it from `String(openSSHPublicKey:)` is one refactor from a fingerprint that no longer matches `ssh-keygen -lf`.
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        hostKey.write(to: &buffer)
        let blob = Data(buffer: buffer)

        // `keyPrefix` is internal to NIOSSH, so the algorithm is read back off the OpenSSH rendering.
        let rendered = String(openSSHPublicKey: hostKey)
        let algorithm = rendered.split(separator: " ").first.map(String.init) ?? "unknown"

        let presented = SSHHostKeyPrompt(
            endpoint: endpoint,
            algorithm: algorithm,
            fingerprint: SSHFingerprint.string(of: blob)
        )

        switch store.decision(for: endpoint, publicKey: blob) {
        case .match:
            validationCompletePromise.succeed(())

        case .changed(let known):
            sessionLog.error("host key changed for \(self.endpoint.key, privacy: .public)")
            validationCompletePromise.fail(
                SSHSessionError.hostKeyChanged(known: known, presented: presented)
            )

        case .unknown:
            let ask = self.ask
            let record = self.record
            Task {
                let accepted = await ask(presented)
                if accepted {
                    record(presented, blob)
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SSHSessionError.hostKeyRejected(presented))
                }
            }
        }
    }
}
