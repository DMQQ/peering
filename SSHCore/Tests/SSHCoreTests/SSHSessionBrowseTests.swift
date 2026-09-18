import Foundation
import Testing

@testable import SSHCore

/// Asking a session about files when there is no shell to ask through.
///
/// The only part of the browse path that can be tested without a server, and it is the part that
/// matters most when there is no server: a request is answered by the command loop inside the
/// connection's own task, so with no loop running it would sit in the command stream's buffer
/// holding a continuation that nothing will ever resume. That is a leak at best and a trap when
/// the stream is deallocated, so the refusal has to be immediate and it has to be a refusal.
@Suite("SSH browse without a shell")
struct SSHSessionBrowseTests {
    /// A session that has never been connected, which is the state these tests are about.
    private func orphan() -> SSHSession {
        SSHSession(
            host: SSHHost(name: "Nowhere", hostname: "127.0.0.1", port: 1, username: "nobody"),
            password: "not a password"
        ) { _ in true }
    }

    private func refusal(_ work: () async throws -> Void) async -> SSHSessionError? {
        do {
            try await work()
            return nil
        } catch let error as SSHSessionError {
            return error
        } catch {
            return .transport(String(describing: error))
        }
    }

    @Test("a listing with nothing attached comes back rather than waiting")
    func listRefused() async {
        let error = await refusal { _ = try await self.orphan().listDirectory(at: ".") }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    @Test("so does a preview")
    func previewRefused() async {
        let error = await refusal { _ = try await self.orphan().readFile(at: "/etc/hosts") }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }
}
