import Testing

@testable import PeeringKit

@Suite("Which capture a rearranged tile is drawn from")
struct MosaicRearrangementTests {
    private let windows = ["a", "b", "c", "d", "e", "f"]

    @Test("a compositor that has just started draws tile i from capture i")
    func aNewCompositorStartsWithIdentity() {
        #expect(MosaicRearrangement.identity(count: 0) == [])
        #expect(MosaicRearrangement.identity(count: 3) == [0, 1, 2])
        #expect(MosaicRearrangement.identity(count: 6) == [0, 1, 2, 3, 4, 5])
    }

    @Test("a row of windows moved to the front takes their captures with them")
    func aReorderFollowsTheWindows() {
        guard let order = MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["c", "d", "e", "a", "b", "f"]
        ) else {
            Issue.record("a reorder of the same windows has an order")
            return
        }
        #expect(order == [2, 3, 4, 0, 1, 5])
    }

    @Test("a window dragged across another swaps exactly those two captures")
    func aSwapSwapsTwoCaptures() {
        guard let order = MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["a", "c", "b", "d", "e", "f"]
        ) else {
            Issue.record("a swap of two windows has an order")
            return
        }
        #expect(order == [0, 2, 1, 3, 4, 5])
    }

    @Test("a second rearrangement is answered from the first, not from the slots")
    func rearrangementsCompose() {
        // Needs two moves to show: after the first, a slot index is no longer a capture index.
        guard let first = MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["c", "a", "b", "d", "e", "f"]
        ) else {
            Issue.record("the first rearrangement has an order")
            return
        }
        #expect(first == [2, 0, 1, 3, 4, 5])

        guard let second = MosaicRearrangement.engineOrder(
            previous: first,
            sources: ["c", "a", "b", "d", "e", "f"],
            slots: ["b", "c", "a", "d", "e", "f"]
        ) else {
            Issue.record("the second rearrangement has an order")
            return
        }
        #expect(second == [1, 2, 0, 3, 4, 5])
    }

    @Test("a turn of the phone keeps every capture where it was")
    func aRotationIsTheIdentity() {
        guard let order = MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: windows
        ) else {
            Issue.record("a turn has an order")
            return
        }
        #expect(order == [0, 1, 2, 3, 4, 5])
    }

    @Test("a window the compositor is not capturing has no order")
    func anUnknownWindowHasNoOrder() {
        // A window added is not a rearrangement: the caller must build a mosaic that captures it.
        #expect(MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["a", "b", "c", "d", "e", "g"]
        ) == nil)

        #expect(MosaicRearrangement.engineOrder(previous: [0, 1], sources: windows, slots: windows) == nil)
    }

    @Test("a tile whose window moved keeps the same source in the same place")
    func everyWindowIsDrawnOnce() {
        for slots in [windows, windows.reversed(), ["f", "e", "d", "c", "b", "a"], ["b", "a", "d", "c", "f", "e"]] {
            guard let order = MosaicRearrangement.engineOrder(
                previous: MosaicRearrangement.identity(count: 6),
                sources: windows,
                slots: Array(slots)
            ) else {
                Issue.record("every arrangement of the same windows has an order")
                return
            }
            #expect(Set(order) == Set(0..<6))
            #expect(order.count == 6)
        }
    }
}
