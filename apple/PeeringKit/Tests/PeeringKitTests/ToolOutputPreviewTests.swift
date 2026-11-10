import Testing
@testable import PeeringKit

struct ToolOutputPreviewTests {
    @Test func shortOutputIsShownWhole() {
        let preview = ToolOutputPreview("one\ntwo", maxLines: 5)
        #expect(preview.shown == "one\ntwo")
        #expect(preview.hiddenLines == 0)
    }

    @Test func longOutputIsCutAtTheLineLimitAndCountsWhatIsHidden() {
        let text = (1...10).map(String.init).joined(separator: "\n")
        let preview = ToolOutputPreview(text, maxLines: 3)
        #expect(preview.shown == "1\n2\n3")
        #expect(preview.hiddenLines == 7)
    }

    @Test func oneHugeLineIsCutAtTheCharacterLimit() {
        let preview = ToolOutputPreview(String(repeating: "x", count: 100), maxLines: 5, maxCharacters: 10)
        #expect(preview.shown.count == 10)
        #expect(preview.hiddenLines == 1)
    }
}
