import Testing

@testable import MacCastKit

struct SentenceTemplateTests {
    @Test func oneArgumentIsReadBackFromTheMiddle() {
        let found = SentenceTemplate.arguments(
            in: "There is no folder at /Users/a/b on this Mac.",
            template: "There is no folder at %@ on this Mac."
        )
        #expect(found == ["/Users/a/b"])
    }

    @Test func twoArgumentsComeBackInOrder() {
        let found = SentenceTemplate.arguments(
            in: "A different Mac answered: one, not two. Check it.",
            template: "A different Mac answered: %@, not %@. Check it."
        )
        #expect(found == ["one", "two"])
    }

    @Test func anArgumentAtTheEndIsTakenWhole() {
        #expect(SentenceTemplate.arguments(in: "Could not start: no such file", template: "Could not start: %@") == ["no such file"])
    }

    @Test func aSentenceBuiltFromAnotherTemplateDoesNotMatch() {
        #expect(SentenceTemplate.arguments(in: "Something else entirely.", template: "There is no folder at %@ on this Mac.") == nil)
        #expect(SentenceTemplate.arguments(in: "There is no folder at /x", template: "There is no folder at %@ on this Mac.") == nil)
    }

    @Test func aTemplateWithoutArgumentsMatchesOnlyItself() {
        #expect(SentenceTemplate.arguments(in: "Done.", template: "Done.") == [])
        #expect(SentenceTemplate.arguments(in: "Done!", template: "Done.") == nil)
    }

    @Test func anEmptyArgumentIsAllowed() {
        #expect(SentenceTemplate.arguments(in: "Terminal \u{201C}\u{201D} is waiting.", template: "Terminal \u{201C}%@\u{201D} is waiting.") == [""])
    }
}
