import Testing
@testable import PeeringKit

@Suite("Sidebar selection")
struct SidebarSelectionTests {
    @Test func aRowPickedWithNothingOpenOpensIt() {
        #expect(SidebarSelection.detailPath(current: [Int](), proposed: [1]) == [1])
    }

    @Test func aRowPickedOverAnOpenPageReplacesIt() {
        #expect(SidebarSelection.detailPath(current: [1, 2], proposed: [1, 2, 3]) == [3])
    }

    @Test func closingThePaneEmptiesIt() {
        #expect(SidebarSelection.detailPath(current: [1, 2], proposed: [Int]()) == [])
    }

    @Test func aReplacedPathStands() {
        #expect(SidebarSelection.detailPath(current: [1, 2], proposed: [1, 4]) == [1, 4])
    }
}
