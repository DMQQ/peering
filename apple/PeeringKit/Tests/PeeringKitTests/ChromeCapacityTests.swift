import CoreGraphics
import Testing

@testable import PeeringKit

@Suite("How many buttons a strip of controls holds")
struct ChromeCapacityTests {
    @Test("a phone's dock keeps its five columns")
    func phoneKeepsFive() {
        #expect(ChromeCapacity.columns(gridWidth: 302, cellWidth: 60, atLeast: 5) == 5)
        #expect(ChromeCapacity.columns(gridWidth: 277, cellWidth: 60, atLeast: 5) == 5)
    }

    @Test("a wide dock gains a column for every cell width it has")
    func wideDockGains() {
        #expect(ChromeCapacity.columns(gridWidth: 542, cellWidth: 60, atLeast: 5) == 9)
    }

    @Test("an unmeasured dock keeps the minimum")
    func unmeasuredDock() {
        #expect(ChromeCapacity.columns(gridWidth: 0, cellWidth: 60, atLeast: 5) == 5)
    }

    @Test("a short rail holds fewer buttons than a tall one")
    func railRows() {
        #expect(ChromeCapacity.rows(height: 488, buttonHeight: 62, gap: 2, padding: 4) == 7)
        #expect(ChromeCapacity.rows(height: 900, buttonHeight: 62, gap: 2, padding: 4) == 13)
        #expect(ChromeCapacity.rows(height: 5, buttonHeight: 62, gap: 2, padding: 4) == 0)
    }

    @Test("optional groups fill in order, the first one cut short if it must")
    func optionalGroups() {
        #expect(ChromeCapacity.optionalCounts(capacity: 7, fixed: 6, groups: [5, 1, 1, 4]) == [1, 0, 0, 0])
        #expect(ChromeCapacity.optionalCounts(capacity: 14, fixed: 6, groups: [5, 1, 1, 4]) == [5, 1, 1, 0])
        #expect(ChromeCapacity.optionalCounts(capacity: 17, fixed: 6, groups: [5, 1, 1, 4]) == [5, 1, 1, 4])
        #expect(ChromeCapacity.optionalCounts(capacity: 4, fixed: 6, groups: [5, 1]) == [0, 0])
    }
}
