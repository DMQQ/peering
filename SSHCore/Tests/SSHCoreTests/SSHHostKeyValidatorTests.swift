import Foundation
import NIO
import NIOSSH
import Testing

@testable import SSHCore

/// The three things a host key can be, and the one that must never be a prompt.
///
/// The validator is the last thing between a user's password and whoever answered the dial, and its
/// whole value is in the branch it *doesn't* take: a key that has changed is a failure, not a
/// question. A test that only checked the happy path would pass just as happily against an
/// implementation that showed the same friendly first-connect prompt for a changed key — which is
/// the attack, because the moment the user is asked is the moment they are being hurried.
///
/// So every test here is written against one of two failure modes: a prompt that should not have
/// been shown, or a store that should not have been written.
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

        // Read after the promise settles, which is what makes "zero" a fact rather than a race: a
        // `.match` completes the promise inside `validateHostKey` itself, so by the time this line
        // runs the validator has returned and nothing of it is still in flight.
        #expect(fixture.spy.askCount == 0)
    }

    @Test("a changed key fails outright, without ever reaching the user")
    func changedKeyNeverAsks() async throws {
        // The attack this check exists to catch. `answer: true` on purpose: if the changed key
        // reached `ask` at all, the user would have said yes — which is exactly what a one-tap
        // "accept the new key" would produce — so this asserts on the prompt never being raised,
        // not on how the user replied to it.
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
            // Both keys travel with the error, because the screen that explains a change has to be
            // able to show what was expected *and* what arrived.
            #expect(stored.publicKey == TestKey.blob(of: known))
            #expect(stored.fingerprint == TestKey.aFingerprint)
            #expect(prompt.fingerprint == TestKey.bFingerprint)
            #expect(prompt.algorithm == "ssh-ed25519")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(fixture.spy.askCount == 0)
        // And the key nobody agreed to is not written down: the entry that was there is still the
        // entry, rather than the arriving key quietly replacing it.
        #expect(fixture.store.host(for: Fixture.endpoint)?.publicKey == TestKey.blob(of: known))
    }

    @Test("a host never seen is put to the user, and stored once they agree")
    func firstSightIsAskedAndRecorded() async throws {
        let fixture = Fixture(answer: true)
        let key = try TestKey.parse(TestKey.a)

        let promise = makePromise()
        fixture.validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        // Waiting on the promise *is* waiting on the ask: the `.unknown` path completes it from the
        // task that ran `ask`, so nothing here depends on how the scheduler got around to it.
        try await promise.futureResult.get()

        let prompt = try #require(fixture.spy.firstAsked)
        #expect(prompt.endpoint == Fixture.endpoint)
        // The algorithm and the fingerprint are what the user actually reads, and the fingerprint
        // is the one `ssh-keygen -lf` prints for this key — the string they can check against the
        // server by another route. A prompt showing anything else is a prompt worth nothing.
        #expect(prompt.algorithm == "ssh-ed25519")
        #expect(prompt.fingerprint == TestKey.aFingerprint)

        // Recorded before the promise completes, so a caller that proceeds on success can rely on
        // the next connection being silent.
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
            // The prompt travels with the error so the screen can repeat what was declined — "you
            // declined this key" is only useful next to the key.
            #expect(prompt.fingerprint == TestKey.aFingerprint)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(fixture.spy.askCount == 1)
        // A no is a no: nothing was trusted, so the next connection asks again rather than
        // connecting silently to a key that was never agreed to.
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

        // One ask across two connections. This is also what pins the blob to its round trip through
        // the store: the key is written as JSON and read back, and a byte that differs on the way
        // out turns every reconnect into a changed key that refuses to connect.
        #expect(fixture.spy.askCount == 1)
    }
}

/// Two real ed25519 public keys, generated with `ssh-keygen -t ed25519` and nothing else.
///
/// Spelled out rather than assembled from bytes because `NIOSSHPublicKey` only accepts a well-formed
/// OpenSSH line, and a blob built by hand that happens not to parse would fail every test in this
/// file for a reason that has nothing to do with the validator. Only the public halves are here, and
/// only they ever could be: this is what a server offers on the wire.
private enum TestKey {
    static let a = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHIVSs2oQ5g8e4MLpXCgb/RP0iTkA7lzZhlSgqqDQm1m test"
    static let b = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcOXPwXhgVM0VgK//ac3X4v9iC0YOJfZg/OQ4rOGFFa test2"

    /// What `ssh-keygen -lf` prints for each of them, which is the point of showing a fingerprint at
    /// all — it is the one thing here a user can check without trusting this code.
    static let aFingerprint = "SHA256:CCYZy/5TaePIbnpoCZWKTv194DbieJyIIgnxX8xCG2w"
    static let bFingerprint = "SHA256:vUTas54ftNE94IhvG4YcVem5VxpzhU5i3dek+tN6Vtk"

    static func parse(_ openSSHPublicKey: String) throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: openSSHPublicKey)
    }

    /// The key as it arrives in the handshake — what the store holds and what a fingerprint is
    /// taken of. Written with the same call the validator uses, so a test can never disagree with
    /// it about what the bytes are.
    static func blob(of key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }
}

/// A secret backend with no Keychain behind it, so no test here can hang on a prompt or touch the
/// real store.
///
/// A class with a lock rather than a struct, for the reason `InMemorySecretBackend` gives: the
/// stores hold this as a `let` and expect the same contents back on the next read, and a value type
/// would hand each of them its own empty copy.
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

/// Stands in for the user, and keeps a record of what they were asked.
///
/// Locked, because `ask` is called from a task inside the validator while the test reads the result
/// from its own thread — and because the interesting assertion is often that the count is *zero*,
/// which only means something if nothing can be arriving behind the test's back as it reads.
private final class AskSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [SSHHostKeyPrompt] = []
    private let answer: Bool

    /// What the user says to every prompt. `true` in the tests that expect no prompt at all, so
    /// that "the user was not asked" cannot be confused with "the user was asked and refused".
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

/// A validator wired the way `SSHSession.run` wires it, plus the two things a test has to watch.
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
            // The closure `SSHSession.run` passes, spelled the same way, so what is asserted below
            // is the store a real connection would leave behind rather than a double's own idea.
            record: { prompt, blob in
                _ = store.record(endpoint: prompt.endpoint, algorithm: prompt.algorithm, publicKey: blob)
            }
        )
    }
}

/// A promise on the group's already-running loop, which is the only kind NIO will complete without
/// a loop being started by hand.
private func makePromise() -> EventLoopPromise<Void> {
    MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
}
