import Foundation
import Testing

@testable import RemoteCore

/// Storage that answers as told and records what was asked, since a Keychain cannot be made to misbehave on cue.
private final class FakeStorage: PinStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [PinSlot: Data] = [:]
    private var failsWrites = false
    private var unavailable = false
    private var failsBackupWrites = false
    private var _written: [Data] = []

    init(stored: Data? = nil, backup: Data? = nil, failsWrites: Bool = false, unavailable: Bool = false) {
        slots[.primary] = stored
        slots[.backup] = backup
        self.failsWrites = failsWrites
        self.unavailable = unavailable
    }

    var written: [Data] { lock.withLock { _written } }
    func failWrites(_ failing: Bool) { lock.withLock { failsWrites = failing } }
    func failBackupWrites(_ failing: Bool) { lock.withLock { failsBackupWrites = failing } }
    func lock(_ locked: Bool) { lock.withLock { unavailable = locked } }
    func stored(_ slot: PinSlot) -> Data? { lock.withLock { slots[slot] } }
    func lose(_ slot: PinSlot) { lock.withLock { slots[slot] = nil } }

    func read(_ slot: PinSlot) -> PinStorageRead {
        lock.withLock {
            if unavailable { return .unavailable }
            return slots[slot].map { .found($0) } ?? .notFound
        }
    }

    func write(_ data: Data, to slot: PinSlot) -> Bool {
        lock.withLock {
            guard !failsWrites, !unavailable, !(slot == .backup && failsBackupWrites) else { return false }
            slots[slot] = data
            _written.append(data)
            return true
        }
    }
}

@Suite("The pin store")
struct PinStoreTests {
    private let mac = Data([0x04] + Array(repeating: 0xab, count: 64))
    private let phone = Data([0x04] + Array(repeating: 0xcd, count: 64))

    @Test func aRecordedPinSurvivesTheStoreThatRecordedIt() {
        let storage = FakeStorage()

        let first = PinStore(storage: storage)
        #expect(first.record(peerID: "mac-1", publicKey: mac))

        let second = PinStore(storage: storage)
        #expect(second.peerIDs == ["mac-1"])
        #expect(second.pin(for: "mac-1") == mac)
        #expect(second.contains(publicKey: mac))
        #expect(!second.contains(publicKey: phone))
    }

    /// A write that did not land must not be remembered as though it had.
    @Test func aWriteThatFailsIsNotRemembered() {
        let storage = FakeStorage(failsWrites: true)
        let store = PinStore(storage: storage)

        #expect(!store.record(peerID: "mac-1", publicKey: mac))
        #expect(store.peerIDs.isEmpty)
        #expect(store.pin(for: "mac-1") == nil)
    }

    @Test func aFailedRepairKeepsTheKeyThatWasAlreadyThere() {
        let storage = FakeStorage()
        let store = PinStore(storage: storage)
        #expect(store.record(peerID: "mac-1", publicKey: mac))

        storage.failWrites(true)
        #expect(!store.record(peerID: "mac-1", publicKey: phone))

        #expect(store.pin(for: "mac-1") == mac)
        #expect(store.contains(publicKey: mac))
        #expect(!store.contains(publicKey: phone))
    }

    /// A failed removal leaves the peer pinned, the safe direction.
    @Test func aFailedRemovalKeepsThePin() {
        let storage = FakeStorage()
        let store = PinStore(storage: storage)
        #expect(store.record(peerID: "mac-1", publicKey: mac))

        storage.failWrites(true)
        #expect(!store.remove(peerID: "mac-1"))
        #expect(store.pin(for: "mac-1") == mac)

        storage.failWrites(false)
        #expect(store.remove(peerID: "mac-1"))
        #expect(store.peerIDs.isEmpty)
    }

    @Test func aFailedRemoveAllKeepsEveryPinInMemoryAndInStorage() {
        let storage = FakeStorage()
        let store = PinStore(storage: storage)
        #expect(store.record(peerID: "mac-1", publicKey: mac))
        #expect(store.record(peerID: "phone-1", publicKey: phone))

        storage.failWrites(true)
        #expect(!store.removeAll())
        #expect(store.pin(for: "mac-1") == mac)
        #expect(store.pin(for: "phone-1") == phone)

        storage.failWrites(false)
        #expect(store.removeAll())
        #expect(store.peerIDs.isEmpty)
    }

    /// Unreadable bytes with no backup are an empty store, not a refusal to run: the cost is a re-pairing rather than the app.
    @Test func unreadableBytesAreAnEmptyStoreRatherThanAFailure() {
        let storage = FakeStorage(stored: Data("not json at all".utf8))
        let store = PinStore(storage: storage)

        #expect(store.peerIDs.isEmpty)
        #expect(store.pin(for: "mac-1") == nil)

        #expect(store.record(peerID: "mac-2", publicKey: phone))
        #expect(store.pin(for: "mac-2") == phone)
    }

    @Test func nothingStoredIsAnEmptyStore() {
        let store = PinStore(storage: FakeStorage())
        #expect(store.isEmpty)
        #expect(store.peerIDs.isEmpty)
    }

    /// `contains` is what the TLS verify block calls, before the peer's ID is known.
    @Test func aKeyThatIsPinnedIsFoundByTheKeyAlone() {
        let store = PinStore(storage: FakeStorage())
        #expect(store.record(peerID: "mac-1", publicKey: mac))
        #expect(store.record(peerID: "phone-1", publicKey: phone))

        #expect(store.peerIDs == ["mac-1", "phone-1"])
        #expect(store.contains(publicKey: mac))
        #expect(store.contains(publicKey: phone))
        #expect(!store.contains(publicKey: Data([0x04] + Array(repeating: 0xee, count: 64))))

        #expect(store.removeAll())
        #expect(store.isEmpty)
    }

    @Test func aStoreThatCannotBeReadRefusesToRecordAndKeepsTheOtherPins() {
        let storage = FakeStorage()
        #expect(PinStore(storage: storage).record(peerID: "phone-a", publicKey: phone))

        storage.lock(true)
        let store = PinStore(storage: storage)
        #expect(!store.isAvailable)
        #expect(!store.record(peerID: "phone-b", publicKey: mac))

        storage.lock(false)
        #expect(store.record(peerID: "phone-b", publicKey: mac))
        #expect(store.peerIDs == ["phone-a", "phone-b"])
        #expect(PinStore(storage: storage).peerIDs == ["phone-a", "phone-b"])
    }

    @Test func aStoreThatCameUpLockedRecoversItsPinsOnTheNextLookup() {
        let storage = FakeStorage()
        #expect(PinStore(storage: storage).record(peerID: "phone-a", publicKey: phone))

        storage.lock(true)
        let store = PinStore(storage: storage)
        #expect(!store.contains(publicKey: phone))

        storage.lock(false)
        #expect(store.contains(publicKey: phone))
        #expect(store.isAvailable)
    }

    @Test func aStoreIsReadAgainBeforeEveryChange() {
        let storage = FakeStorage()
        let stale = PinStore(storage: storage)
        let other = PinStore(storage: storage)
        #expect(other.record(peerID: "phone-a", publicKey: phone))

        #expect(stale.record(peerID: "phone-b", publicKey: mac))
        #expect(PinStore(storage: storage).peerIDs == ["phone-a", "phone-b"])
    }

    @Test func removalsAndClearingAreRefusedWhileTheStoreIsLocked() {
        let storage = FakeStorage()
        let store = PinStore(storage: storage)
        #expect(store.record(peerID: "phone-a", publicKey: phone))

        storage.lock(true)
        #expect(!store.remove(peerID: "phone-a"))
        #expect(!store.removeAll())

        storage.lock(false)
        #expect(store.pin(for: "phone-a") == phone)
    }

    @Test func everyWriteLandsInTheBackupToo() {
        let storage = FakeStorage()
        let store = PinStore(storage: storage)
        #expect(store.record(peerID: "phone-a", publicKey: phone))
        #expect(storage.stored(.backup) == storage.stored(.primary))
        #expect(storage.stored(.backup) != nil)
    }

    @Test func aLostPrimaryIsRestoredFromTheBackup() {
        let storage = FakeStorage()
        #expect(PinStore(storage: storage).record(peerID: "phone-a", publicKey: phone))
        storage.lose(.primary)

        let store = PinStore(storage: storage)
        #expect(store.pin(for: "phone-a") == phone)
        #expect(store.record(peerID: "phone-b", publicKey: mac))
        #expect(storage.stored(.primary) != nil)
    }

    @Test func aCorruptPrimaryFallsBackToTheBackup() {
        let valid = FakeStorage()
        #expect(PinStore(storage: valid).record(peerID: "phone-a", publicKey: phone))
        let storage = FakeStorage(stored: Data("garbage".utf8), backup: valid.stored(.backup))

        #expect(PinStore(storage: storage).pin(for: "phone-a") == phone)
    }

    @Test func aBackupThatCannotBeWrittenDoesNotFailThePairing() {
        let storage = FakeStorage()
        storage.failBackupWrites(true)
        let store = PinStore(storage: storage)

        #expect(store.record(peerID: "phone-a", publicKey: phone))
        #expect(store.pin(for: "phone-a") == phone)
    }
}
