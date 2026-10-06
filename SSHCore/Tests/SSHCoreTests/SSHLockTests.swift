import Foundation
import Testing

@testable import SSHCore

private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "peering.ssh.lock.tests.\(UUID().uuidString)")!
}

@Suite("A server's lock")
struct SSHPasscodeStoreTests {
    @Test("a passcode opens the server it was set on, and nothing else")
    func setThenVerify() {
        let store = SSHPasscodeStore(backend: InMemorySecretBackend())
        let host = UUID()
        let other = UUID()

        #expect(!store.hasPasscode(for: host))
        #expect(store.set("481620", for: host))
        #expect(store.hasPasscode(for: host))

        #expect(store.verify("481620", for: host))
        #expect(!store.verify("481621", for: host))
        // A passcode set on one server is not a passcode for every server; `true` for an unknown id would make the lock a screen.
        #expect(!store.verify("481620", for: other))
    }

    @Test("setting a passcode again replaces the old one")
    func overwrite() {
        let store = SSHPasscodeStore(backend: InMemorySecretBackend())
        let host = UUID()
        store.set("111111", for: host)
        store.set("222222", for: host)

        #expect(store.verify("222222", for: host))
        #expect(!store.verify("111111", for: host))
        #expect(store.all().count == 1)
    }

    @Test("removing one leaves the others alone")
    func remove() {
        let store = SSHPasscodeStore(backend: InMemorySecretBackend())
        let first = UUID()
        let second = UUID()
        store.set("111111", for: first)
        store.set("222222", for: second)

        #expect(store.remove(for: first))
        #expect(!store.verify("111111", for: first))
        #expect(store.verify("222222", for: second))
    }

    @Test("removing something that was never there is not a failure")
    func removingNothingSucceeds() {
        #expect(SSHPasscodeStore(backend: InMemorySecretBackend()).remove(for: UUID()))
    }

    @Test("the same six digits on two servers do not store the same bytes")
    func saltSeparatesIdenticalPasscodes() {
        // Without the salt, equal passcodes on two servers would be recognisable from the blob.
        let store = SSHPasscodeStore(backend: InMemorySecretBackend())
        let first = UUID()
        let second = UUID()
        store.set("123456", for: first)
        store.set("123456", for: second)

        #expect(store.hash(for: first) != store.hash(for: second))
        #expect(store.verify("123456", for: first))
        #expect(store.verify("123456", for: second))
    }

    @Test("anything that is not six digits is refused")
    func lengthIsEnforced() {
        let store = SSHPasscodeStore(backend: InMemorySecretBackend())
        let host = UUID()

        #expect(!SSHPasscodeStore.isValid("12345"))
        #expect(!SSHPasscodeStore.isValid("1234567"))
        #expect(!SSHPasscodeStore.isValid("12345a"))
        // `isNumber` alone accepts non-ASCII digits, which a pad could never let the user type back.
        #expect(!SSHPasscodeStore.isValid("١٢٣٤٥٦"))
        #expect(SSHPasscodeStore.isValid("000000"))

        #expect(!store.set("123", for: host))
        #expect(!store.hasPasscode(for: host))
    }

    @Test("a backend that refuses the write is reported, not swallowed")
    func failedWriteIsReported() {
        #expect(SSHPasscodeStore(backend: RefusingSecretBackend()).set("123456", for: UUID()) == false)
    }

    @Test("a passcode survives a reopen, which is the whole point of storing it")
    func survivesReopen() {
        let backend = InMemorySecretBackend()
        let host = UUID()
        SSHPasscodeStore(backend: backend).set("481620", for: host)

        #expect(SSHPasscodeStore(backend: backend).verify("481620", for: host))
    }
}

private struct RefusingSecretBackend: SSHSecretBackend {
    func read(service: String, account: String) -> Data? { nil }
    @discardableResult func write(_ data: Data, service: String, account: String) -> Bool { false }
    @discardableResult func remove(service: String, account: String) -> Bool { false }
}

@Suite("Servers saved before the lock existed")
struct SSHHostLockDecodingTests {
    private func legacyBlob(id: UUID) -> Data {
        Data("""
        [{"id":"\(id.uuidString)","name":"","hostname":"box.local","port":22,"username":"root","createdAt":0}]
        """.utf8)
    }

    @Test("the list loads, and nothing in it is locked")
    func missingKeyDecodesToUnlocked() throws {
        // A property default is not a decoding default: a `lock` field without a hand-written decoder made every saved server fail to decode, and the store then returned an empty list.
        let defaults = scratchDefaults()
        defaults.set(legacyBlob(id: UUID()), forKey: SSHHostStore.key)

        let hosts = SSHHostStore(defaults: defaults).load()

        #expect(hosts.count == 1)
        #expect(hosts.first?.lock == .off)
        #expect(hosts.first?.hostname == "box.local")
    }

    @Test("a lock this build does not know degrades to unlocked, and takes nothing else with it")
    func unknownLockDoesNotThrow() throws {
        // A value from a newer build: throwing would cost every server, degrading costs a lock this build could not enforce anyway.
        let id = UUID()
        let defaults = scratchDefaults()
        let json = """
        [{"id":"\(id.uuidString)","name":"Prod","hostname":"box.local","port":22,"username":"root",\
        "createdAt":0,"lock":"hardwareKey"}]
        """
        defaults.set(Data(json.utf8), forKey: SSHHostStore.key)

        let hosts = SSHHostStore(defaults: defaults).load()

        #expect(hosts.count == 1)
        #expect(hosts.first?.lock == .off)
        #expect(hosts.first?.name == "Prod")
    }

    @Test("a lock round-trips through storage")
    func lockSurvivesStorage() {
        let store = SSHHostStore(defaults: scratchDefaults())
        let host = SSHHost(name: "Prod", hostname: "box.local", username: "root", lock: .passcode)

        store.save([host])

        #expect(store.load() == [host])
        #expect(store.load().first?.lock == .passcode)
    }
}

@Suite("The connection log")
struct SSHConnectionHistoryTests {
    private func record(
        host: UUID = UUID(),
        outcome: SSHConnectionRecord.Outcome = .connected,
        from start: TimeInterval = 0,
        to end: TimeInterval = 120
    ) -> SSHConnectionRecord {
        SSHConnectionRecord(
            hostID: host,
            name: "Prod",
            detail: "root@box.local",
            startedAt: Date(timeIntervalSince1970: start),
            endedAt: Date(timeIntervalSince1970: end),
            outcome: outcome
        )
    }

    @Test("round-trips through storage")
    func roundTrip() {
        let store = SSHConnectionHistoryStore(defaults: scratchDefaults())
        let written = record(outcome: .failed("The server's key has changed."))

        store.save([written])

        #expect(store.load() == [written])
    }

    @Test("an empty store is empty, not a crash")
    func emptyStore() {
        #expect(SSHConnectionHistoryStore(defaults: scratchDefaults()).load().isEmpty)
    }

    @Test("the log keeps the newest and drops the oldest")
    func capped() {
        // The cap is the length on screen as well as on disk; an unbounded blob would grow with every connection.
        let store = SSHConnectionHistoryStore(defaults: scratchDefaults())
        let many = (0..<(SSHConnectionHistoryStore.limit + 10)).map { record(from: Double($0)) }

        store.save(many)

        let loaded = store.load()
        #expect(loaded.count == SSHConnectionHistoryStore.limit)
        #expect(loaded.first?.startedAt == many.first?.startedAt)
    }

    @Test("a duration is never negative, however the two stamps arrived")
    func durationIsClamped() {
        let backwards = record(from: 300, to: 100)
        #expect(backwards.duration == 0)
        #expect(record().duration == 120)
    }

    @Test("the name and the address are kept, so a deleted server still reads")
    func recordOutlivesTheHost() {
        // The record holds its own copy of the name, so deleting a server does not blank the log.
        let gone = UUID()
        let store = SSHConnectionHistoryStore(defaults: scratchDefaults())
        store.save([record(host: gone)])

        let loaded = store.load()
        #expect(loaded.first?.name == "Prod")
        #expect(loaded.first?.detail == "root@box.local")
    }

    @Test("the two outcomes are distinguishable, and a failure carries its reason")
    func outcomes() {
        #expect(record(outcome: .connected).outcome.isConnected)
        #expect(record(outcome: .connected).outcome.reason == nil)

        let failure = record(outcome: .failed("The server's key has changed.")).outcome
        #expect(!failure.isConnected)
        #expect(failure.reason == "The server's key has changed.")
    }
}
