import Testing

@testable import MacCastKit

@Suite("Which capture a rearranged tile is drawn from")
struct MosaicRearrangementTests {
    /// Six windows, named by what they are rather than by where they are.
    private let windows = ["a", "b", "c", "d", "e", "f"]

    @Test("a compositor that has just started draws tile i from capture i")
    func aNewCompositorStartsWithIdentity() {
        #expect(MosaicRearrangement.identity(count: 0) == [])
        #expect(MosaicRearrangement.identity(count: 3) == [0, 1, 2])
        #expect(MosaicRearrangement.identity(count: 6) == [0, 1, 2, 3, 4, 5])
    }

    @Test("a row of windows moved to the front takes their captures with them")
    func aReorderFollowsTheWindows() {
        // c, d and e dragged to the front: every slot's capture is the one that was holding the
        // window now in it, and nothing about the captures themselves changed.
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
        // **The bug this exists for, and it needs two moves to show.** A slot's index stops being
        // a capture's index the moment the first window moves, so the second rearrangement — a
        // window moved and then the phone turned, or two windows moved in turn — cannot be read
        // off the tiles. The old code looked up the *slot* a window had and used that as a capture
        // index, which was right once and wrong every time after.
        guard let first = MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["c", "a", "b", "d", "e", "f"]
        ) else {
            Issue.record("the first rearrangement has an order")
            return
        }
        #expect(first == [2, 0, 1, 3, 4, 5])

        // A second move, against the arrangement the first one left: b to the front.
        guard let second = MosaicRearrangement.engineOrder(
            previous: first,
            sources: ["c", "a", "b", "d", "e", "f"],
            slots: ["b", "c", "a", "d", "e", "f"]
        ) else {
            Issue.record("the second rearrangement has an order")
            return
        }
        // b is the capture at index 1, c at 2, a at 0 — which is what the first move had already
        // recorded, and what reading positions off the new arrangement cannot give.
        #expect(second == [1, 2, 0, 3, 4, 5])
    }

    @Test("a turn of the phone keeps every capture where it was")
    func aRotationIsTheIdentity() {
        // The same windows in the same order on a canvas of another shape: the captures are not
        // rearranged at all, only re-pointed.
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
        // A window added to the arrangement is not a rearrangement: the caller has to build a
        // mosaic that captures it, and an order invented for it would draw six windows into five
        // captures and one rectangle of nothing.
        #expect(MosaicRearrangement.engineOrder(
            previous: MosaicRearrangement.identity(count: 6),
            sources: windows,
            slots: ["a", "b", "c", "d", "e", "g"]
        ) == nil)

        // And a mapping that does not describe the arrangement it is paired with is not one to
        // build on.
        #expect(MosaicRearrangement.engineOrder(previous: [0, 1], sources: windows, slots: windows) == nil)
    }

    @Test("a tile whose window moved keeps the same source in the same place")
    func everyWindowIsDrawnOnce() {
        // Every capture appears exactly once, whatever the arrangement: a permutation rather than
        // a mapping with a repeat in it, which is the shape of a shuffle.
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
