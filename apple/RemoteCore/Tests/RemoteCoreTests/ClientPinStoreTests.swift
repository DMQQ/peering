import Foundation
import Security
import Testing
@testable import RemoteCore

private final class FakeKeychain: ClientPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var lockedStatus: OSStatus?
    private var failingWrites = false

    func read(_ slot: PinSlot) -> PinRead {
        lock.withLock {
            if let lockedStatus { return .unavailable(lockedStatus) }
            return items["\(slot)"].map(PinRead.found) ?? .notFound
        }
    }

    func write(_ data: Data, to slot: PinSlot) -> Bool {
        lock.withLock {
            if lockedStatus != nil || failingWrites { return false }
            items["\(slot)"] = data
            return true
        }
    }

    func lockKeychain() { lock.withLock { lockedStatus = errSecInteractionNotAllowed } }
    func unlockKeychain() { lock.withLock { lockedStatus = nil } }
    func failWrites() { lock.withLock { failingWrites = true } }
    func corruptPrimary() { lock.withLock { items["primary"] = Data("not json".utf8) } }
    func deletePrimary() { lock.withLock { items["primary"] = nil } }
}

@Suite struct ClientPinStoreTests {
    private let key = Data([1, 2, 3])
    private let other = Data([4, 5, 6])

    @Test func anEmptyKeychainIsNotUnreadable() {
        let store = ClientPinStore(backing: FakeKeychain())
        #expect(!store.isUnreadable)
        #expect(store.isEmpty)
    }

    @Test func aLockedKeychainIsUnreadableNotEmpty() {
        let keychain = FakeKeychain()
        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        #expect(store.isUnreadable)
        #expect(store.pin(for: "mac") == nil)
    }

    @Test func recordingWhileUnreadableIsRefusedAndWritesNothing() {
        let keychain = FakeKeychain()
        #expect(ClientPinStore(backing: keychain).record(hostID: "old", publicKey: key))

        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        #expect(store.record(hostID: "new", publicKey: other) == false)

        keychain.unlockKeychain()
        #expect(ClientPinStore(backing: keychain).hostIDs == ["old"])
    }

    @Test func aStoreThatBecameReadableKeepsTheEarlierPinsWhenRecording() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "old", publicKey: key)

        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        keychain.unlockKeychain()

        #expect(store.record(hostID: "new", publicKey: other))
        #expect(store.hostIDs == ["new", "old"])
    }

    @Test func aWriteReReadsSoAnotherWritersPinSurvives() {
        let keychain = FakeKeychain()
        let first = ClientPinStore(backing: keychain)
        let second = ClientPinStore(backing: keychain)
        #expect(first.record(hostID: "a", publicKey: key))
        #expect(second.record(hostID: "b", publicKey: other))
        #expect(ClientPinStore(backing: keychain).hostIDs == ["a", "b"])
    }

    @Test func aLockedKeychainThatOpensLaterIsReadAgainOnLookup() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "mac", publicKey: key)
        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        #expect(store.pin(for: "mac") == nil)
        keychain.unlockKeychain()
        #expect(store.pin(for: "mac") == key)
        #expect(!store.isUnreadable)
    }

    @Test func aCorruptPrimaryIsRestoredFromTheBackup() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "mac", publicKey: key)
        keychain.corruptPrimary()
        #expect(ClientPinStore(backing: keychain).pin(for: "mac") == key)
    }

    @Test func aMissingPrimaryIsRestoredFromTheBackup() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "mac", publicKey: key)
        keychain.deletePrimary()
        #expect(ClientPinStore(backing: keychain).pin(for: "mac") == key)
    }

    @Test func aFailedWriteLeavesThePinsAsTheyWere() {
        let keychain = FakeKeychain()
        let store = ClientPinStore(backing: keychain)
        _ = store.record(hostID: "old", publicKey: key)
        keychain.failWrites()
        #expect(store.record(hostID: "new", publicKey: other) == false)
        #expect(store.hostIDs == ["old"])
    }

    @Test func theUnreadableNoticeComesOnceAndOnlyWhileUnreadable() {
        let keychain = FakeKeychain()
        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        #expect(store.takeUnreadableNotice())
        #expect(!store.takeUnreadableNotice())

        #expect(!ClientPinStore(backing: FakeKeychain()).takeUnreadableNotice())
    }
}
