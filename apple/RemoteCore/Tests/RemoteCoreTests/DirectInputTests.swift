import Foundation
import Testing
@testable import RemoteCore

struct DirectInputTests {
    private let move = RemoteCommand.mouseMove(to: NormalizedPoint(x: 0.5, y: 0.5))

    @Test func movesGoDirectWhenThePathIsOpenAndTheHostAccepts() {
        var route = DirectInputRoute()
        let path = route.route(move, now: 10, directIsOpen: true, hostAccepts: true)
        #expect(path == .direct)
    }

    @Test func movesStayOnControlWithoutAnOpenPathOrAHostThatAccepts() {
        var route = DirectInputRoute()
        let closed = route.route(move, now: 10, directIsOpen: false, hostAccepts: true)
        let refused = route.route(move, now: 10, directIsOpen: true, hostAccepts: false)
        #expect(closed == .control)
        #expect(refused == .control)
    }

    @Test func aClickKeepsFollowingMovesOnControlUntilTheQuietPeriodPasses() {
        var route = DirectInputRoute()
        let click = route.route(.mouseDown(button: .left), now: 10, directIsOpen: false, hostAccepts: true)
        let soon = route.route(move, now: 10.3, directIsOpen: true, hostAccepts: true)
        let later = route.route(move, now: 10.7, directIsOpen: true, hostAccepts: true)
        #expect(click == .control)
        #expect(soon == .control)
        #expect(later == .direct)
    }

    @Test func clicksAndKeysGoOnBothPathsWhenTheDirectPathIsOpen() {
        var route = DirectInputRoute()
        let click = route.route(.mouseUp(button: .left), now: 10, directIsOpen: true, hostAccepts: true)
        let key = route.route(.keyDown(keyCode: 0, modifiers: []), now: 10, directIsOpen: true, hostAccepts: true)
        let text = route.route(.textInput("hi"), now: 10, directIsOpen: true, hostAccepts: true)
        #expect(click == .both)
        #expect(key == .both)
        #expect(text == .control)
    }

    @Test func theSecondCopyOfAClickIsDroppedWhicheverPathDeliveredFirst() {
        var filter = DuplicateInputFilter()
        let down = RemoteCommand.mouseDown(button: .left)
        let results = [
            filter.shouldApply(down, from: .direct, now: 1),
            filter.shouldApply(down, from: .control, now: 1.1),
            filter.shouldApply(down, from: .control, now: 2),
            filter.shouldApply(down, from: .direct, now: 2.1)
        ]
        #expect(results == [true, false, true, false])
    }

    @Test func aCopyWhoseTwinWasLostDoesNotSwallowTheNextCommand() {
        var filter = DuplicateInputFilter()
        let key = RemoteCommand.keyDown(keyCode: 0, modifiers: [])
        let results = [
            filter.shouldApply(key, from: .control, now: 1),
            filter.shouldApply(key, from: .direct, now: 2),
            filter.shouldApply(key, from: .control, now: 2.1)
        ]
        #expect(results == [true, false, true])
    }

    @Test func movementIsNeverFiltered() {
        var filter = DuplicateInputFilter()
        let move = RemoteCommand.mouseMove(to: NormalizedPoint(x: 0.1, y: 0.1))
        let results = [filter.shouldApply(move, from: .direct, now: 1), filter.shouldApply(move, from: .control, now: 1)]
        #expect(results == [true, true])
    }

    @Test func olderSequencesAreRefusedAndWrapAroundIsNewer() {
        var order = DirectInputOrder()
        let results = [order.accepts(5), order.accepts(5), order.accepts(4), order.accepts(6)]
        #expect(results == [true, false, false, true])

        var wrapping = DirectInputOrder()
        let last: UInt32 = 4_294_967_295
        let first: UInt32 = 0
        let accepted = wrapping.accepts(last)
        let wrapped = wrapping.accepts(first)
        #expect(accepted)
        #expect(wrapped)
    }

    @Test func aDirectCommandSurvivesTheWire() throws {
        let sent = DirectCommand(sequence: 7, command: .scroll(dx: 1, dy: -2))
        let data = try JSONEncoder().encode(sent)
        let received = try JSONDecoder().decode(DirectCommand.self, from: data)
        #expect(received == sent)
    }
}
