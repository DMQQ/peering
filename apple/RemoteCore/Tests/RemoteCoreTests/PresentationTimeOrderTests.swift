import Testing

@testable import RemoteCore

struct PresentationTimeOrderTests {
    @Test func aLaterTimeIsKept() {
        #expect(PresentationTimeOrder.strictlyAfter(10.5, last: 10.0) == 10.5)
    }

    @Test func theFirstTimeIsKept() {
        #expect(PresentationTimeOrder.strictlyAfter(3.0, last: nil) == 3.0)
    }

    @Test func anEarlierOrEqualTimeIsMovedOneStepPastTheLast() {
        #expect(PresentationTimeOrder.strictlyAfter(9.998, last: 10.0) == 10.001)
        #expect(PresentationTimeOrder.strictlyAfter(10.0, last: 10.0) == 10.001)
    }
}
