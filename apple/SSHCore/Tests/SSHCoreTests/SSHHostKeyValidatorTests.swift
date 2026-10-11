import Foundation
import NIO
import NIOSSH
import Testing

@testable import SSHCore

/// A changed key is a failure, not a question: a friendly prompt for it is the attack, since the user is being hurried. Every test is written against a prompt that should not have been shown or a store that should not have been written.
@Suite("Host key validator")
struct SSHHostKeyValidatorTests {
    @Test("a known key connects, and nobody is asked")
    func knownKeyIsAccepted() async throws {
        let fixture = Fixture(answer: true)
        let key = try TestKey.parse(TestKey.a)
        fixture.store.record(
            endpoint: Fixture.endpoint,
            algorithm: "ssh-ed25519",
            publicKey: TestKey.blob(of: key)
        )

        let promise = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        try await promise.futureResult.get()

        // Read after the promise settles: a `.match` completes it inside `validateHostKey`, so nothing is still in flight.
        #expect(fixture.spy.askCount == 0)
    }

    @Test("a changed key fails outright, without ever reaching the user")
    func changedKeyNeverAsks() async throws {
        // `answer: true` on purpose: this asserts the prompt is never raised, not how the user replied.
        let fixture = Fixture(answer: true)
        let known = try TestKey.parse(TestKey.a)
        let presented = try TestKey.parse(TestKey.b)
        fixture.store.record(
            endpoint: Fixture.endpoint,
            algorithm: "ssh-ed25519",
            publicKey: TestKey.blob(of: known)
        )

        let promise = makePromise()
        fixture.validator.validateHostKey(hostKey: presented, validationCompletePromise: promise)

        do {
            try await promise.futureResult.get()
            Issue.record("a changed host key must fail the handshake, not complete it")
        } catch let error as SSHSessionError {
            guard case .hostKeyChanged(let stored, let prompt) = error else {
                Issue.record("expected .hostKeyChanged, got \(error)")
                return
            }
            #expect(stored.publicKey == TestKey.blob(of: known))
            #expect(stored.fingerprint == TestKey.aFingerprint)
            #expect(prompt.fingerprint == TestKey.bFingerprint)
            #expect(prompt.algorithm == "ssh-ed25519")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(fixture.spy.askCount == 0)
        #expect(fixture.store.host(for: Fixture.endpoint)?.publicKey == TestKey.blob(of: known))
    }

    @Test("a host never seen is put to the user, and stored once they agree")
    func firstSightIsAskedAndRecorded() async throws {
        let fixture = Fixture(answer: true)
        let key = try TestKey.parse(TestKey.a)

        let promise = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        try await promise.futureResult.get()

        let prompt = try #require(fixture.spy.firstAsked)
        #expect(prompt.endpoint == Fixture.endpoint)
        #expect(prompt.algorithm == "ssh-ed25519")
        #expect(prompt.fingerprint == TestKey.aFingerprint)

        // Recorded before the promise completes, so the next connection is silent.
        #expect(fixture.store.host(for: Fixture.endpoint)?.publicKey == TestKey.blob(of: key))
        #expect(fixture.store.host(for: Fixture.endpoint)?.fingerprint == TestKey.aFingerprint)
    }

    @Test("a first-sight key the user declines is refused, and not written down")
    func declinedFirstSightIsRejected() async throws {
        let fixture = Fixture(answer: false)
        let key = try TestKey.parse(TestKey.a)

        let promise = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: promise)

        do {
            try await promise.futureResult.get()
            Issue.record("a declined host key must fail the handshake, not complete it")
        } catch let error as SSHSessionError {
            guard case .hostKeyRejected(let prompt) = error else {
                Issue.record("expected .hostKeyRejected, got \(error)")
                return
            }
            #expect(prompt.fingerprint == TestKey.aFingerprint)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(fixture.spy.askCount == 1)
        #expect(fixture.store.host(for: Fixture.endpoint) == nil)
    }

    @Test("accepting a first-sight key makes the next connection silent")
    func recordedKeyIsTrustedOnTheNextConnect() async throws {
        let fixture = Fixture(answer: true)
        let key = try TestKey.parse(TestKey.a)

        let first = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: first)
        try await first.futureResult.get()

        let second = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: second)
        try await second.futureResult.get()

        // One ask across two connections; this also pins the blob's JSON round trip, since a differing byte would turn every reconnect into a changed key.
        #expect(fixture.spy.askCount == 1)
    }
}

/// Two real ed25519 public keys from `ssh-keygen`: `NIOSSHPublicKey` only accepts a well-formed OpenSSH line, so a hand-built blob could fail every test for an unrelated reason.
private enum TestKey {
    static let a = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHIVSs2oQ5g8e4MLpXCgb/RP0iTkA7lzZhlSgqqDQm1m test"
    static let b = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcOXPwXhgVM0VgK//ac3X4v9iC0YOJfZg/OQ4rOGFFa test2"

    static let aFingerprint = "SHA256:CCYZy/5TaePIbnpoCZWKTv194DbieJyIIgnxX8xCG2w"
    static let bFingerprint = "SHA256:vUTas54ftNE94IhvG4YcVem5VxpzhU5i3dek+tN6Vtk"

    static func parse(_ openSSHPublicKey: String) throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: openSSHPublicKey)
    }

    static func blob(of key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }
}

/// A secret backend with no Keychain, so no test can hang on a prompt. A class with a lock because stores expect the same contents back on the next read.
private final class ScratchBackend: SSHSecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    func read(service: String, account: String) -> Data? {
        lock.withLock { storage[key(service, account)] }
    }

    @discardableResult
    func write(_ data: Data, service: String, account: String) -> Bool {
        lock.withLock { storage[key(service, account)] = data }
        return true
    }

    @discardableResult
    func remove(service: String, account: String) -> Bool {
        lock.withLock { storage.removeValue(forKey: key(service, account)) != nil }
    }
}

/// Stands in for the user and records what they were asked. Locked because `ask` runs in a task inside the validator while the test reads from its own thread.
private final class AskSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [SSHHostKeyPrompt] = []
    private let answer: Bool

    /// `true` in tests that expect no prompt, so "not asked" cannot be confused with "asked and refused".
    init(answer: Bool) {
        self.answer = answer
    }

    func ask(_ prompt: SSHHostKeyPrompt) async -> Bool {
        lock.withLock { asked.append(prompt) }
        return answer
    }

    var askCount: Int { lock.withLock { asked.count } }
    var firstAsked: SSHHostKeyPrompt? { lock.withLock { asked.first } }
}

private struct Fixture {
    static let endpoint = SSHEndpoint(hostname: "box.local", port: 22)

    let store: SSHKnownHosts
    let spy: AskSpy
    let validator: SSHHostKeyValidator

    init(answer: Bool) {
        let store = SSHKnownHosts(backend: ScratchBackend())
        let spy = AskSpy(answer: answer)
        let endpoint = Self.endpoint
        self.store = store
        self.spy = spy
        self.validator = SSHHostKeyValidator(
            endpoint: endpoint,
            store: store,
            ask: { prompt in await spy.ask(prompt) },
            record: { prompt, blob in
                _ = store.record(endpoint: prompt.endpoint, algorithm: prompt.algorithm, publicKey: blob)
            }
        )
    }
}

/// A promise on the group's already-running loop, the only kind NIO completes without a hand-started loop.
private func makePromise() -> EventLoopPromise<Void> {
    MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
}
