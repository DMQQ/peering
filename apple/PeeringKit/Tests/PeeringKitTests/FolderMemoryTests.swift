import Foundation
import Testing

@testable import PeeringKit

@Suite("Remembering the folder the Files browser was in")
struct FolderMemoryTests {
    private func memory() -> FolderMemory {
        let suite = "FolderMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return FolderMemory(defaults: defaults)
    }

    @Test("A Mac with nothing remembered has no folder")
    func startsEmpty() {
        #expect(memory().folder(for: "Studio") == nil)
    }

    @Test("The folder comes back for the Mac that was browsed")
    func remembersPerMac() {
        let memory = memory()
        memory.remember("/Users/dmq/Projects", for: "Studio")
        memory.remember("/Volumes/Backup", for: "Laptop")
        #expect(memory.folder(for: "Studio") == "/Users/dmq/Projects")
        #expect(memory.folder(for: "Laptop") == "/Volumes/Backup")
    }

    @Test("A later folder replaces the earlier one")
    func lastWins() {
        let memory = memory()
        memory.remember("/a", for: "Studio")
        memory.remember("/a/b", for: "Studio")
        #expect(memory.folder(for: "Studio") == "/a/b")
    }

    @Test("Forgetting clears one Mac and leaves the others")
    func forgetsOne() {
        let memory = memory()
        memory.remember("/a", for: "Studio")
        memory.remember("/b", for: "Laptop")
        memory.forget(for: "Studio")
        #expect(memory.folder(for: "Studio") == nil)
        #expect(memory.folder(for: "Laptop") == "/b")
    }

    @Test("Only absolute paths are kept")
    func ignoresRelativePaths() {
        let memory = memory()
        memory.remember("Documents", for: "Studio")
        #expect(memory.folder(for: "Studio") == nil)
    }
}
