import Testing
import PeeringKit

@Suite("Folder access slots")
struct FolderAccessSlotsTests {
    @Test("a subfolder of a protected folder shares the folder's key")
    func subfolderSharesKey() {
        #expect(FolderAccessSlots.key(for: "/Users/a/Desktop/project/src", home: "/Users/a") == "/Users/a/Desktop")
        #expect(FolderAccessSlots.key(for: "/Users/a/Documents", home: "/Users/a/") == "/Users/a/Documents")
        #expect(FolderAccessSlots.key(for: "/Users/a/Downloads/../Downloads/x", home: "/Users/a") == "/Users/a/Downloads")
    }

    @Test("a path outside the protected folders keys on itself, standardized")
    func otherPathKeysOnItself() {
        #expect(FolderAccessSlots.key(for: "/Users/a/code/./app/", home: "/Users/a") == "/Users/a/code/app")
        #expect(FolderAccessSlots.key(for: "/Users/a/DesktopNotes", home: "/Users/a") == "/Users/a/DesktopNotes")
    }

    @Test("a second claim on the same folder waits until the first is released")
    func oneReaderPerKey() {
        var slots = FolderAccessSlots()
        let first = slots.claim("/Users/a/Desktop")
        let second = slots.claim("/Users/a/Desktop")
        let other = slots.claim("/Users/a/Documents")
        slots.release("/Users/a/Desktop")
        let afterRelease = slots.claim("/Users/a/Desktop")
        #expect(first)
        #expect(!second)
        #expect(other)
        #expect(afterRelease)
    }
}
