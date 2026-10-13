import Foundation
import Security
import Testing
@testable import RemoteCore

private final class FakeKeychain: ClientPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var lockedStatus: OSStatus?
    private var failingWrites = false
    private var failingDeletes = false

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

    func delete(_ slot: PinSlot) -> Bool {
        lock.withLock {
            if lockedStatus != nil || failingDeletes { return false }
            items["\(slot)"] = nil
            return true
        }
    }

    func lockKeychain() { lock.withLock { lockedStatus = errSecInteractionNotAllowed } }
    func unlockKeychain() { lock.withLock { lockedStatus = nil } }
    func failDeletes() { lock.withLock { failingDeletes = true } }
    func failWrites() { lock.withLock { failingWrites = true } }
    func corruptPrimary() { lock.withLock { items["primary"] = Data("not json".utf8) } }
    func deletePrimary() { lock.withLock { items["primary"] = nil } }
    func deleteBackup() { lock.withLock { items["backup"] = nil } }
    func corruptBackup() { lock.withLock { items["backup"] = Data("not json".utf8) } }
    var primaryBytes: Data? { lock.withLock { items["primary"] } }
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

    @Test func aCorruptPrimaryWithNoBackupIsUnreadableAndNeverOverwritten() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "mac", publicKey: key)
        keychain.corruptPrimary()
        keychain.deleteBackup()
        let raised = Raised()
        let alarm = PinStoreAlarm()
        alarm.install { raised.add($0) }
        let store = ClientPinStore(backing: keychain, alarm: alarm)
        #expect(store.isUnreadable)
        #expect(raised.all == [nil])
        #expect(store.record(hostID: "new", publicKey: other) == false)
        #expect(keychain.primaryBytes == Data("not json".utf8))
    }

    @Test func aCorruptBackupWithNoPrimaryIsUnreadableToo() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "mac", publicKey: key)
        keychain.deletePrimary()
        keychain.corruptBackup()
        #expect(ClientPinStore(backing: keychain, alarm: PinStoreAlarm()).isUnreadable)
    }

    @Test func anAlarmRaisedBeforeAnyHandlerExistsIsDeliveredOnInstall() {
        let keychain = FakeKeychain()
        keychain.lockKeychain()
        let alarm = PinStoreAlarm()
        _ = ClientPinStore(backing: keychain, alarm: alarm)
        let raised = Raised()
        alarm.install { raised.add($0) }
        #expect(raised.all == [errSecInteractionNotAllowed])
        alarm.install { raised.add($0) }
        #expect(raised.all.count == 1)
    }

    @Test func aHandlerThatReEntersTheStoreIsRunOutsideTheLock() {
        let keychain = FakeKeychain()
        let alarm = PinStoreAlarm()
        let store = ClientPinStore(backing: keychain, alarm: alarm)
        let seen = Raised()
        alarm.install { _ in seen.add(store.isUnreadable ? 1 : 0) }
        keychain.lockKeychain()
        #expect(store.record(hostID: "new", publicKey: other) == false)
        #expect(seen.all == [1])
    }

    @Test func aCorruptPrimaryWithNoBackupIsCorruptAndCanBeReset() {
        let keychain = FakeKeychain()
        keychain.corruptPrimary()
        let store = ClientPinStore(backing: keychain)
        #expect(store.unreadableState == .corrupt)
        #expect(store.unreadableState?.canBeReset == true)
    }

    @Test func aLockedKeychainIsUnavailableAndCannotBeReset() {
        let keychain = FakeKeychain()
        keychain.lockKeychain()
        let store = ClientPinStore(backing: keychain)
        #expect(store.unreadableState == .keychainUnavailable)
        #expect(store.unreadableState?.canBeReset == false)
        #expect(!store.resetCorrupt())
    }

    @Test func aReadableStoreHasNoUnreadableState() {
        let store = ClientPinStore(backing: FakeKeychain())
        #expect(store.unreadableState == nil)
    }

    @Test func resettingACorruptStoreDeletesBothItemsAndAllowsPairingAgain() {
        let keychain = FakeKeychain()
        _ = ClientPinStore(backing: keychain).record(hostID: "old", publicKey: key)
        keychain.corruptPrimary()
        keychain.corruptBackup()
        let store = ClientPinStore(backing: keychain)
        #expect(store.record(hostID: "new", publicKey: other) == false)

        #expect(store.resetCorrupt())

        #expect(store.unreadableState == nil)
        #expect(store.isEmpty)
        #expect(keychain.primaryBytes == nil)
        #expect(store.record(hostID: "new", publicKey: other))
        #expect(ClientPinStore(backing: keychain).hostIDs == ["new"])
    }

    @Test func resetRefusesAReadableStoreSoNoGoodPinIsErased() {
        let keychain = FakeKeychain()
        let store = ClientPinStore(backing: keychain)
        _ = store.record(hostID: "mac", publicKey: key)

        #expect(!store.resetCorrupt())
        #expect(store.hostIDs == ["mac"])
    }

    @Test func resetFailsAndStaysCorruptWhenTheItemsCannotBeDeleted() {
        let keychain = FakeKeychain()
        keychain.corruptPrimary()
        let store = ClientPinStore(backing: keychain)
        keychain.failDeletes()

        #expect(!store.resetCorrupt())
        #expect(store.unreadableState == .corrupt)
    }

}

private final class Raised: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int32?] = []
    func add(_ status: Int32?) { lock.withLock { statuses.append(status) } }
    var all: [Int32?] { lock.withLock { statuses } }
}
