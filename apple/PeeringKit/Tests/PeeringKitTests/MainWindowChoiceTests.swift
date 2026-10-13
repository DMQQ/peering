import Testing

@testable import PeeringKit

struct MainWindowChoiceTests {
    @Test func theWindowNamedForTheGroupWinsOverAnEarlierOneThatCouldBeMain() {
        let index = MainWindowChoice.index(
            of: "main", identifiers: [nil, "main-AppWindow-1"], canBecomeMain: [true, true]
        )
        #expect(index == 1)
    }

    @Test func aWindowWhoseNameOnlyStartsWithTheIDIsNotTheGroup() {
        let index = MainWindowChoice.index(of: "main", identifiers: ["mainframe"], canBecomeMain: [false])
        #expect(index == nil)
    }

    @Test func withNoNamedWindowTheFirstThatCanBecomeMainIsUsed() {
        let index = MainWindowChoice.index(of: "main", identifiers: ["popover", nil], canBecomeMain: [false, true])
        #expect(index == 1)
    }

    @Test func noWindowAtAllMeansTheCallerMustOpenOne() {
        #expect(MainWindowChoice.index(of: "main", identifiers: [], canBecomeMain: []) == nil)
    }
}
