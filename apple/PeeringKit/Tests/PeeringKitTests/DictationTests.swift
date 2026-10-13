import Testing
@testable import PeeringKit

struct DictationTests {
    @Test func silenceDrawsNoBar() {
        #expect(DictationLevels.level(forDecibels: -80) == 0)
        #expect(DictationLevels.level(forDecibels: -.infinity) == 0)
    }

    @Test func loudSpeechFillsTheBar() {
        #expect(DictationLevels.level(forDecibels: 0) == 1)
        #expect(DictationLevels.level(forDecibels: 10) == 1)
    }

    @Test func aQuieterVoiceDrawsASmallerBar() {
        #expect(DictationLevels.level(forDecibels: -30) < DictationLevels.level(forDecibels: -10))
    }

    @Test func theNewestLevelIsLastAndTheCountStaysFixed() {
        var levels = DictationLevels()
        levels.add(decibels: 0)
        #expect(levels.bars.count == DictationLevels.barCount)
        #expect(levels.bars.last == 1)
        #expect(levels.bars.first == 0)
    }

    @Test func spokenTextIsSeparatedFromAWordBeforeIt() {
        #expect(DictationText.insertion(after: "ls", spoken: " -la ") == " -la")
        #expect(DictationText.insertion(after: "ls ", spoken: "-la") == "-la")
        #expect(DictationText.insertion(after: "", spoken: "hello") == "hello")
        #expect(DictationText.insertion(after: "ls", spoken: "  ").isEmpty)
    }
}
