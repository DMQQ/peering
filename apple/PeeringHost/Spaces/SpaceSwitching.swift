import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import RemoteCore
import os

private let spaceLog = Logger(subsystem: "pl.dmq.peering.host", category: "spaces")

// MARK: - Making the picture follow the switch

/// `AXUIElementPostKeyboardEvent`, which is the only route by which a simulated ⌃←/⌃→ reaches
/// the window server's symbolic hot key match.
private typealias PostKeyboardEventFunc = @convention(c) (
    AXUIElement?, CGCharCode, CGKeyCode, Bool
) -> AXError

private let postKeyboardEvent: PostKeyboardEventFunc? = {
    guard let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY
    ), let symbol = dlsym(handle, "AXUIElementPostKeyboardEvent") else { return nil }
    return unsafeBitCast(symbol, to: PostKeyboardEventFunc.self)
}()

/// Whether a chord posted from here will be acted on.
private var canPostSpaceChords: Bool {
    postKeyboardEvent != nil && AXIsProcessTrusted()
}

private let chordControlKeyCode: CGKeyCode = 59
private let chordLeftKeyCode: CGKeyCode = 123
private let chordRightKeyCode: CGKeyCode = 124

private let chordApproachDelay = DispatchTimeInterval.milliseconds(150)

private let chordKeyGapMilliseconds = 25

/// Posts ⌃←/⌃→, spread over the main queue.
private func spaceCentre(of displayID: UInt32) -> CGPoint {
    let bounds = CGDisplayBounds(displayID)
    return CGPoint(x: bounds.midX, y: bounds.midY)
}

private func postSpaceChord(_ direction: SpaceDirection) {
    let arrow = direction == .left ? chordLeftKeyCode : chordRightKeyCode
    let events: [(key: CGKeyCode, down: Bool)] = [
        (chordControlKeyCode, true),
        (arrow, true),
        (arrow, false),
        (chordControlKeyCode, false),
    ]
    for (step, event) in events.enumerated() {
        let deadline = DispatchTime.now() + .milliseconds(chordKeyGapMilliseconds * step)
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            postKeyEvent(event.key, down: event.down)
        }
    }
}

/// One key event, posted system-wide through the Accessibility subsystem.
private func postKeyEvent(_ key: CGKeyCode, down: Bool) {
    guard let post = postKeyboardEvent else { return }
    _ = post(AXUIElementCreateSystemWide(), 0, key, down)
}

/// The Space to jump to, and the way to step off it onto `spaceID`.
private func chordApproach(
    display: ManagedDisplay, spaceID: Int32
) -> ChordApproach {
    guard canPostSpaceChords else { return .unusable(.noPermission) }
    guard display.displayID == DisplayGeometry.pointerDisplayID() else {
        return .unusable(.pointerElsewhere)
    }

    let spaces = display.spaces
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
        return .unusable(.noApproach)
    }
    if index > 0 { return .step(neighbour: spaces[index - 1].id, direction: .right) }
    if index < spaces.count - 1 { return .step(neighbour: spaces[index + 1].id, direction: .left) }
    return .unusable(.noApproach)
}

private enum ChordApproach {
    case step(neighbour: Int32, direction: SpaceDirection)
    case unusable(SpaceSwitchRoute.DirectReason)
}

/// The direct call on its own: instant, and correct only as the approach to a real transition.
@discardableResult
private func setCurrentSpace(display: ManagedDisplay, spaceID: Int32) -> Bool {
    guard let connection = cgsConnection, let setCurrent = cgsSetManagedDisplayCurrentSpace else {
        return false
    }
    let cid = connection()
    guard cid > 0 else { return false }
    return setCurrent(cid, display.identifier as CFString, UInt64(spaceID)) == 0
}

/// How a switch reached the Space it was asked for.
enum SpaceSwitchRoute: Sendable, Equatable {
    case chord
    case direct(DirectReason)
    case refused

    enum DirectReason: Sendable, Equatable {
        case noPermission
        case pointerElsewhere
        case chordDidNotLand
        case noApproach
    }
}

/// Moves `display` onto `spaceID`, **and makes the picture follow it.**
///
/// **The direct call on its own is not enough.** Setting the current Space updates what the
/// window server considers current without running the Dock's switch.
func performSwitch(
    display: ManagedDisplay,
    spaceID: Int32,
    report: (@Sendable (SpaceSwitchRoute) -> Void)? = nil
) -> Bool {
    let approach: (neighbour: Int32, direction: SpaceDirection)
    switch chordApproach(display: display, spaceID: spaceID) {
    case .step(let neighbour, let direction):
        approach = (neighbour, direction)
    case .unusable(let reason):
        // The stacked-desktop bug comes straight back the moment the chord route is
        // unavailable, and it comes back *silently*, the switch still happens, only the
        // picture stops following it. So say which half is missing. A second screen or a
        // display with one Space is an ordinary reason to be here and says nothing.
        if reason == .noPermission {
            spaceLog.notice("""
                no Space chords: symbol \(postKeyboardEvent != nil, privacy: .public), \
                accessibility \(AXIsProcessTrusted(), privacy: .public). Switching directly, \
                which can leave the old desktop composited on screen.
                """)
        }
        guard setCurrentSpace(display: display, spaceID: spaceID) else {
            report?(.refused)
            return false
        }
        report?(.direct(reason))
        return true
    }
    // A neighbour the window server refuses to make current leaves the chord stepping off the
    // Space we are already on, which lands somewhere nobody asked for. The direct call is what
    // there is to fall back to.
    guard setCurrentSpace(display: display, spaceID: approach.neighbour) else {
        guard setCurrentSpace(display: display, spaceID: spaceID) else {
            report?(.refused)
            return false
        }
        report?(.direct(.noApproach))
        return true
    }

    let displayID = display.displayID

    // **A chord acts on the display the pointer is on, and this Mac may have several.** Left
    // wherever the user last had it, the chord moves the *other* screen's Space: the display
    // being switched stays on the neighbour, the check below reads that as a chord that never
    // landed, and the direct setter is used, which is the stacked picture this whole route
    let pointerWas = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(spaceCentre(of: displayID))

    DispatchQueue.main.asyncAfter(deadline: .now() + chordApproachDelay) {
        postSpaceChord(approach.direction)

        if let pointerWas {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(chordKeyGapMilliseconds * 6)) {
                CGWarpMouseCursorPosition(pointerWas)
            }
        }

        // A chord that was dropped, the permission withdrawn mid-session, a Space removed
        // between the two reads, leaves the display sitting on the neighbour. Looked at once
        // the slide would have finished, and only corrected if that is still where it is: if
        // the Space has moved anywhere else then somebody else moved it, and putting it back
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700)) {
            guard let now = readDisplays().first(where: { $0.displayID == displayID }),
                  now.activeID == approach.neighbour
            else {
                report?(.chord)
                return
            }
            spaceLog.notice("""
                chord to space \(spaceID, privacy: .public) did not land; still on \
                \(approach.neighbour, privacy: .public), so setting it directly
                """)
            if setCurrentSpace(display: now, spaceID: spaceID) {
                report?(.direct(.chordDidNotLand))
            } else {
                report?(.refused)
            }
        }
    }
    return true
}
