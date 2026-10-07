import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

let fileLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// Deliberately not `Sendable` and never stored: it holds the `SSHClient`, which cannot cross an isolation boundary. It lives inside the PTY closure's task, which is why there is no lock and a browse request is answered inline on the command loop.
final class SSHFileService {
    /// Settled on the first request so the fallback is probed once: a server's SFTP subsystem does not appear mid-session, and re-asking costs a stalled command loop.
    enum Provider {
        case undecided
        case sftp
        case exec
    }

    let client: SSHClient
    var provider: Provider = .undecided
    var start: String?

    init(client: SSHClient) {
        self.client = client
    }

    /// Never throws: the caller is a continuation that must be resumed exactly once.
    func answer(_ request: SSHBrowseRequest) async {
        do {
            switch request.kind {
            case .list:
                request.continuation.resume(returning: .listing(try await directory(at: request.path)))
            case .preview:
                request.continuation.resume(returning: .contents(try await contents(at: request.path)))
            case .write(let contents):
                request.continuation.resume(
                    returning: .written(try await write(contents, to: request.path))
                )
            case .change(let operation):
                request.continuation.resume(
                    returning: .changed(note: try await change(operation))
                )
            }
        } catch let error as SSHSessionError {
            request.continuation.resume(throwing: error)
        } catch {
            request.continuation.resume(throwing: SSHSessionError.browse(Self.describe(error)))
        }
    }






}
