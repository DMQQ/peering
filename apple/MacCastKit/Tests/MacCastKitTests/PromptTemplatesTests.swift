import Foundation
import Testing

@testable import MacCastKit

@Suite struct PromptTemplatesTests {
    @Test func theNewestPromptComesFirst() {
        var templates = PromptTemplates()
        templates.add("run the tests")
        templates.add("fix and commit")
        #expect(templates.entries.map(\.text) == ["fix and commit", "run the tests"])
    }

    @Test func blankAndRepeatedPromptsAreIgnored() {
        var templates = PromptTemplates()
        let blank = templates.add("   \n")
        let first = templates.add("run the tests")
        let repeated = templates.add(" run the tests ")
        #expect(!blank)
        #expect(first)
        #expect(!repeated)
        #expect(templates.entries.count == 1)
    }

    @Test func theOldestGivesWayAtTheLimit() {
        var templates = PromptTemplates()
        for number in 0...PromptTemplates.maximumCount { templates.add("prompt \(number)") }
        #expect(templates.entries.count == PromptTemplates.maximumCount)
        #expect(!templates.entries.contains { $0.text == "prompt 0" })
    }

    @Test func aLongPromptIsCut() {
        var templates = PromptTemplates()
        templates.add(String(repeating: "a", count: 900))
        #expect(templates.entries[0].text.count == PromptTemplates.maximumLength)
    }

    @Test func removingOneKeepsTheRest() {
        var templates = PromptTemplates()
        let id = UUID()
        templates.add("one", id: id)
        templates.add("two")
        templates.remove(id)
        #expect(templates.entries.map(\.text) == ["two"])
    }

    @Test func theyReloadAsSaved() {
        let name = "PromptTemplatesTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        var templates = PromptTemplates()
        templates.add("run the tests")
        templates.save(to: store)
        #expect(PromptTemplates.load(from: store) == templates)
    }
}
