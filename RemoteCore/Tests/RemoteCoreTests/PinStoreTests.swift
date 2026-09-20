import Foundation
import Testing

@testable import RemoteCore

/// Storage that answers whatever the test tells it to, and remembers what was asked of it.
///
/// The point of the whole file: a pin store's interesting behaviour is what it does when storage
/// misbehaves, and there was no way to make a Keychain misbehave on cue. This is the seam.
private final class FakeStorage: PinStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var _written: [Data] = []
    private var failsWrites = false

    init(stored: Data? = nil, failsWrites: Bool = false) {
        self.stored = stored
        self.failsWrites = failsWrites
    }

    var written: [Data] { lock.withLock { _written } }
    func failWrites(_ failing: Bool) { lock.withLock { failsWrites = failing } }

    func read() -> Data? { lock.withLock { stored } }

    func write(_ data: Data) -> Bool {
        lock.withLock {
            guard !failsWrites else { return false }
            stored = data
            _written.append(data)
            return true
        }
    }
}

/// The store that decides which devices may drive this Mac.
///
/// It had no tests at all, which is a strange thing to be able to say about the file that answers
/// "who is allowed in". What is covered here is narrow and deliberate: the rules about *failure*,
/// which are the ones that cannot be reasoned about by reading a happy path, and which a Keychain
/// could never be asked to demonstrate.
@Suite("The pin store")
struct PinStoreTests {
    private let mac = Data([0x04] + Array(repeating: 0xab, count: 64))
    private let phone = Data([0x04] + Array(repeating: 0xcd, count: 64))

    /// The ordinary road: a pairing is recorded, and the next store built over the same storage
    /// finds it. This is also what makes the failure cases below meaningful — they are all
    /// assertions that this does *not* happen.
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

    /// **The rule this file exists for.** A write that did not land must not be remembered as
    /// though it had: the pairing screen reads the answer, and telling somebody they are paired
    /// while the next launch finds nothing is the failure this rollback prevents.
    @Test func aWriteThatFailsIsNotRemembered() {
        let storage = FakeStorage(failsWrites: true)
        let store = PinStore(storage: storage)

        #expect(!store.record(peerID: "mac-1", publicKey: mac))
        #expect(store.peerIDs.isEmpty)
        #expect(store.pin(for: "mac-1") == nil)
    }

    /// And a *re*-pairing that fails puts the previous key back rather than leaving the peer
    /// pinned to nothing. A Mac that was reachable a second ago must not become unreachable
    /// because a write it did not need went wrong.
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

    /// Forgetting is the same shape: a removal that did not land leaves the peer pinned, which is
    /// the safe direction — the alternative is telling the Mac's owner a device is gone while it
    /// can still connect.
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

    /// Bytes that are not a pin store at all are treated as an empty one rather than as whatever
    /// they happen to decode to, and rather than as a reason to refuse to run. The user cost is a
    /// re-pairing; refusing to start would cost them the app.
    @Test func unreadableBytesAreAnEmptyStoreRatherThanAFailure() {
        let storage = FakeStorage(stored: Data("not json at all".utf8))
        let store = PinStore(storage: storage)

        #expect(store.peerIDs.isEmpty)
        #expect(store.pin(for: "mac-1") == nil)

        // And it can still be used, which is the part that matters: a store that read nothing
        // must still be able to write.
        #expect(store.record(peerID: "mac-2", publicKey: phone))
        #expect(store.pin(for: "mac-2") == phone)
    }

    /// An empty read is the first-run case, and must not be confused with a store whose contents
    /// are an empty dictionary: both end up empty, and neither is an error.
    @Test func nothingStoredIsAnEmptyStore() {
        let store = PinStore(storage: FakeStorage())
        #expect(store.isEmpty)
        #expect(store.peerIDs.isEmpty)
    }

    /// Two peers, two keys, and a lookup by key that says which of them it is. `contains` is what
    /// the TLS verify block calls, and it is asked before the peer's ID is known.
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
}
