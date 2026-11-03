import Testing

@testable import PeeringKit

struct AgentCitationTests {
    @Test func quotesEachLineAndLeavesRoomToAnswer() {
        #expect(AgentCitation.append("one\ntwo", to: "") == "> one\n> two\n\n")
    }

    @Test func keepsWhatWasAlreadyTyped() {
        #expect(AgentCitation.append("one", to: "why?") == "why?\n\n> one\n\n")
    }

    @Test func blankLinesInsideStayPartOfTheQuote() {
        #expect(AgentCitation.append("a\n\nb", to: "") == "> a\n>\n> b\n\n")
    }

    @Test func emptyPassageChangesNothing() {
        #expect(AgentCitation.append("  \n", to: "draft") == "draft")
    }

    @Test func longPassageIsClipped() {
        let quoted = AgentCitation.append(String(repeating: "x", count: 5_000), to: "")
        #expect(quoted.count < 1_300)
        #expect(quoted.hasSuffix("…\n\n"))
    }
}
