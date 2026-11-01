import PeeringKit
import RemoteCore
import Testing

@Suite struct TrackpadSwipeCommandsTests {
    private let spaces = SpaceInfo(displays: [SpaceDisplay(displayID: 7, count: 3, current: 2)])

    @Test func swipingLeftMovesToTheDesktopOnTheRight() {
        #expect(TrackpadSwipe.left.commands(spaces: spaces) == [.switchToSpace(display: 7, index: 3)])
    }

    @Test func swipingRightMovesToTheDesktopOnTheLeft() {
        #expect(TrackpadSwipe.right.commands(spaces: spaces) == [.switchToSpace(display: 7, index: 1)])
    }

    @Test func swipingPastTheLastDesktopSendsNothing() {
        let last = SpaceInfo(displays: [SpaceDisplay(displayID: 7, count: 3, current: 3)])
        #expect(TrackpadSwipe.left.commands(spaces: last).isEmpty)
    }

    @Test func withoutADesktopListTheRelativeChordStandsIn() {
        #expect(TrackpadSwipe.left.commands(spaces: nil) == [.switchSpace(direction: .right)])
        #expect(TrackpadSwipe.right.commands(spaces: nil) == [.switchSpace(direction: .left)])
    }

    @Test func swipingUpOpensMissionControl() {
        #expect(TrackpadSwipe.up.commands(spaces: spaces) == [
            .keyDown(keyCode: 126, modifiers: .control), .keyUp(keyCode: 126, modifiers: .control),
        ])
    }

    @Test func swipingDownShowsTheAppsWindows() {
        #expect(TrackpadSwipe.down.commands(spaces: spaces) == [
            .keyDown(keyCode: 125, modifiers: .control), .keyUp(keyCode: 125, modifiers: .control),
        ])
    }
}
