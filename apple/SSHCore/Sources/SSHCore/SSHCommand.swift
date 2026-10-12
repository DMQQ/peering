import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

/// A continuation, as for ``SSHBrowseRequest``. This hands back a live channel, which is safe because NIO's `Channel` is `Sendable` (every method hops onto its own event loop); the client that made it is not and stays in the task.
struct SSHForwardRequest: Sendable {
    let host: String
    let port: Int
    let localPort: Int
    let continuation: CheckedContinuation<NIOAsyncChannel<ByteBuffer, ByteBuffer>, any Error>
}

enum SSHCommand: Sendable {
    case write(Data)
    case resize(columns: Int, rows: Int)
    case browse(SSHBrowseRequest)
    case forward(SSHForwardRequest)
    case close
}

/// The two-window problem of ``ShellHandle/isAttached`` with different windows: a forward is legitimate from when the transport is up (before the shell attaches, while keyboard-interactive may still be authenticating) until the command loop ends. The shell's flag would refuse the first and allow the second. A lock because the reader is a synchronous `guard`.
final class SSHConnectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isUp = false

    var value: Bool {
        get { lock.withLock { isUp } }
        set { lock.withLock { isUp = newValue } }
    }
}
