import Foundation
import Testing

@testable import SSHCore

/// A `UserDefaults` of its own, so a test never writes into the real app's preferences and never
/// has to tidy up after itself.
private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "peering.ssh.tests.\(UUID().uuidString)")!
}

@Suite("Hosts")
struct SSHHostTests {
    @Test("round-trips through storage")
    func roundTrip() {
        let store = SSHHostStore(defaults: scratchDefaults())
        let host = SSHHost(name: "Build box", hostname: "10.0.0.4", port: 2222, username: "deploy")

        store.save([host])

        #expect(store.load() == [host])
    }

    @Test("an empty store is empty, not a crash")
    func emptyStore() {
        #expect(SSHHostStore(defaults: scratchDefaults()).load().isEmpty)
    }

    @Test("a name nobody gave falls back to the hostname")
    func displayName() {
        let unnamed = SSHHost(hostname: "box.local", username: "root")
        #expect(unnamed.displayName == "box.local")

        let named = SSHHost(name: "Prod", hostname: "box.local", username: "root")
        #expect(named.displayName == "Prod")
    }

    @Test("the default port is left out of the detail line, a custom one is not")
    func detail() {
        #expect(SSHHost(hostname: "box.local", username: "root").detail == "root@box.local")
        #expect(SSHHost(hostname: "box.local", port: 2222, username: "root").detail == "root@box.local:2222")
    }

    @Test("the list shows the most recently used first, and never-used ones in the order added")
    func ordering() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let never = SSHHost(hostname: "c", username: "u", createdAt: early)
        let recent = SSHHost(hostname: "b", username: "u", createdAt: early, lastConnectedAt: late)
        let older = SSHHost(hostname: "a", username: "u", createdAt: early, lastConnectedAt: early)
        let neverLatest = SSHHost(hostname: "d", username: "u", createdAt: late)

        let ordered = SSHHostStore.ordered([never, older, neverLatest, recent]).map(\.hostname)

        #expect(ordered == ["b", "a", "c", "d"])
    }

    @Test("a hostname's case does not make two entries")
    func endpointKeyIsCaseInsensitive() {
        let shouty = SSHEndpoint(hostname: "Host.Example.com", port: 22)
        let quiet = SSHEndpoint(hostname: "host.example.com", port: 22)
        #expect(shouty.key == quiet.key)
    }

    @Test("the same host on two ports is two entries, because it is two servers with two keys")
    func portIsPartOfTheKey() {
        #expect(SSHEndpoint(hostname: "box", port: 22).key != SSHEndpoint(hostname: "box", port: 2222).key)
    }
}

@Suite("Credentials")
struct SSHCredentialStoreTests {
    @Test("saves, reads back, and removes")
    func roundTrip() {
        let store = SSHCredentialStore(backend: InMemorySecretBackend())
        let id = UUID()

        #expect(!store.hasCredential(for: id))
        #expect(store.save(.password("hunter2"), for: id))
        #expect(store.credential(for: id) == .password("hunter2"))
        #expect(store.hasCredential(for: id))

        #expect(store.remove(for: id))
        #expect(store.credential(for: id) == nil)
    }

    @Test("saving again replaces rather than accumulating")
    func overwrite() {
        let store = SSHCredentialStore(backend: InMemorySecretBackend())
        let id = UUID()
        store.save(.password("old"), for: id)
        store.save(.password("new"), for: id)

        #expect(store.credential(for: id) == .password("new"))
        #expect(store.all().count == 1)
    }

    @Test("one host's credential is not another's")
    func keyedByHost() {
        let store = SSHCredentialStore(backend: InMemorySecretBackend())
        let first = UUID()
        let second = UUID()
        store.save(.password("one"), for: first)
        store.save(.password("two"), for: second)

        #expect(store.credential(for: first) == .password("one"))
        #expect(store.credential(for: second) == .password("two"))
    }

    @Test("a backend that refuses the write is reported, not swallowed")
    func failedWriteIsReported() {
        // The whole reason `save` returns a Bool: the caller has to be able to tell the user their
        // password was *not* kept, rather than showing a tick and asking for it again next time.
        let store = SSHCredentialStore(backend: RefusingBackend())
        #expect(store.save(.password("hunter2"), for: UUID()) == false)
    }

    @Test("removing something that was never there is not a failure")
    func removingNothingSucceeds() {
        let store = SSHCredentialStore(backend: InMemorySecretBackend())
        #expect(store.remove(for: UUID()))
    }
}

private struct RefusingBackend: SSHSecretBackend {
    func read(service: String, account: String) -> Data? { nil }
    @discardableResult func write(_ data: Data, service: String, account: String) -> Bool { false }
    @discardableResult func remove(service: String, account: String) -> Bool { false }
}

@Suite("Known hosts")
struct SSHKnownHostsTests {
    static let endpoint = SSHEndpoint(hostname: "box.local", port: 22)
    static let keyA = Data([0x01, 0x02, 0x03])
    static let keyB = Data([0x09, 0x08, 0x07])

    @Test("a host never seen is unknown")
    func firstSight() {
        let hosts = SSHKnownHosts(backend: InMemorySecretBackend())
        #expect(hosts.decision(for: Self.endpoint, publicKey: Self.keyA) == .unknown)
    }

    @Test("after recording, the same key matches")
    func match() {
        let hosts = SSHKnownHosts(backend: InMemorySecretBackend())
        #expect(hosts.record(endpoint: Self.endpoint, algorithm: "ssh-ed25519", publicKey: Self.keyA))
        #expect(hosts.decision(for: Self.endpoint, publicKey: Self.keyA) == .match(hosts.host(for: Self.endpoint)!))
    }

    @Test("a different key for a known host is a change, not a first sight")
    func changed() {
        // The distinction the whole feature rests on. Treated as "unknown", a changed key would
        // bring up the same friendly first-connect prompt a genuine new host does, and the user
        // would accept it — which is precisely the attack the check exists to catch.
        let hosts = SSHKnownHosts(backend: InMemorySecretBackend())
        hosts.record(endpoint: Self.endpoint, algorithm: "ssh-ed25519", publicKey: Self.keyA)

        guard case .changed(let existing) = hosts.decision(for: Self.endpoint, publicKey: Self.keyB) else {
            Issue.record("a different key must be .changed, not .unknown")
            return
        }
        #expect(existing.publicKey == Self.keyA)
    }

    @Test("forgetting a host makes the next connection a first sight again")
    func forget() {
        let hosts = SSHKnownHosts(backend: InMemorySecretBackend())
        hosts.record(endpoint: Self.endpoint, algorithm: "ssh-ed25519", publicKey: Self.keyA)
        #expect(hosts.forget(Self.endpoint))
        #expect(hosts.decision(for: Self.endpoint, publicKey: Self.keyA) == .unknown)
    }

    @Test("the same host on another port is another entry")
    func portSeparatesEntries() {
        let hosts = SSHKnownHosts(backend: InMemorySecretBackend())
        hosts.record(endpoint: SSHEndpoint(hostname: "box.local", port: 22), algorithm: "ssh-ed25519", publicKey: Self.keyA)

        let otherPort = SSHEndpoint(hostname: "box.local", port: 2222)
        #expect(hosts.decision(for: otherPort, publicKey: Self.keyB) == .unknown)
    }

    @Test("an entry survives a round trip through storage with its fingerprint intact")
    func fingerprintSurvivesStorage() {
        let backend = InMemorySecretBackend()
        let hosts = SSHKnownHosts(backend: backend)
        hosts.record(endpoint: Self.endpoint, algorithm: "ssh-ed25519", publicKey: Self.keyA)

        let reopened = SSHKnownHosts(backend: backend)
        #expect(reopened.host(for: Self.endpoint)?.fingerprint == SSHFingerprint.string(of: Self.keyA))
    }
}

@Suite("Quick commands")
struct SSHQuickCommandTests {
    @Test("a chip with no name is called by the first word of its command")
    func titleFallsBackToTheCommand() {
        let command = SSHQuickCommand(title: "  ", command: "docker compose up -d")
        #expect(command.displayTitle == "docker")
    }

    @Test("a name wins when there is one")
    func titleIsUsedWhenGiven() {
        #expect(SSHQuickCommand(title: "Deploy", command: "kubectl apply -f .").displayTitle == "Deploy")
    }

    @Test("round-trips through storage")
    func roundTrip() {
        let store = SSHQuickCommandStore(defaults: scratchDefaults())
        let command = SSHQuickCommand(title: "Logs", command: "journalctl -fu api")
        store.save([command])
        #expect(store.load() == [command])
    }
}
