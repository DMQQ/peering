import ApplicationServices
import ColorSync
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import RemoteCore
import os

private let spaceLog = Logger(subsystem: "pl.dmq.peering.host", category: "spaces")

// The window server's Space API lives in SkyLight.framework, a private framework with no public
// SDK declarations, so every entry point here is resolved by name rather than linked.

/// **`nonisolated(unsafe)`, and the promise being made here is a small one.**
///
/// `dlopen` hands back a pointer this file only ever reads, `let` binds it once, and `dlsym`
/// against a handle is documented as thread-safe.
private nonisolated(unsafe) let skyLight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_NOW
)

/// Resolves `name` inside SkyLight, then in everything else already loaded.
private func resolve(_ name: String) -> UnsafeMutableRawPointer? {
    if let handle = skyLight, let symbol = dlsym(handle, name) { return symbol }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private func resolveFirst(_ names: [String]) -> UnsafeMutableRawPointer? {
    for name in names {
        if let symbol = resolve(name) { return symbol }
    }
    return nil
}

private typealias ConnectionFunc = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias SetCurrentSpaceFunc = @convention(c) (Int32, CFString, UInt64) -> Int32

/// The connection every call below shares.
private let cgsConnection: ConnectionFunc? = resolveFirst([
    "SLSMainConnectionID",
    "CGSMainConnectionID",
    "SLSDefaultConnectionForThread",
    "CGSDefaultConnectionForThread",
    "_SLSDefaultConnection",
    "_CGSDefaultConnection",
]).map { unsafeBitCast($0, to: ConnectionFunc.self) }

private let cgsCopyManagedDisplaySpaces: CopyManagedDisplaySpacesFunc? = resolveFirst([
    "SLSCopyManagedDisplaySpaces",
    "CGSCopyManagedDisplaySpaces",
]).map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFunc.self) }

private let cgsSetManagedDisplayCurrentSpace: SetCurrentSpaceFunc? = resolveFirst([
    "SLSManagedDisplaySetCurrentSpace",
    "CGSManagedDisplaySetCurrentSpace",
]).map { unsafeBitCast($0, to: SetCurrentSpaceFunc.self) }

/// One display's entry in the window server's per-display Space lists.
struct ManagedSpace: Sendable, Equatable {
    let id: Int32
    let isFullscreen: Bool
    /// The application owning a fullscreen Space, from the window server's `pid`.
    ///
    /// The only way to name one — a Space has a number and a UUID, and neither is a name.
    let pid: Int32?
}

struct ManagedDisplay {
    let displayID: UInt32
    let identifier: String
    /// Every Space on this display, in order — desktops and fullscreen applications alike.
    let spaces: [ManagedSpace]
    let activeID: Int32

    var ids: [Int32] { spaces.map(\.id) }

    /// The desktops, in order. What the client is offered and what it may switch to.
    var desktopIDs: [Int32] { spaces.filter { !$0.isFullscreen }.map(\.id) }

    var current: Int? {
        desktopIDs.firstIndex(of: activeID).map { $0 + 1 }
    }

    var fullscreen: ManagedSpace? {
        spaces.first { $0.isFullscreen && $0.id == activeID }
    }
}

/// Every display's UUID, by the `CGDirectDisplayID` it belongs to.
private func displayIDsByIdentifier() -> [String: UInt32] {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return [:] }

    var byIdentifier: [String: UInt32] = [:]
    for id in ids.prefix(Int(count)) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
        byIdentifier[CFUUIDCreateString(nil, uuid) as String] = id
    }
    return byIdentifier
}

private func displayID(forIdentifier identifier: String, in byIdentifier: [String: UInt32]) -> UInt32? {
    if let id = byIdentifier[identifier] { return id }
    // A mirror set or a virtual display can carry a UUID that no `CGDirectDisplayID` reports.
    // The main display is the one worth rescuing by hand, because that fallback is exactly what
    // this reader did when it knew about only one display.
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
          CFUUIDCreateString(nil, uuid) as String == identifier
    else { return nil }
    return CGMainDisplayID()
}

/// Every display's Spaces, **main display first**.
private func readDisplays() -> [ManagedDisplay] {
    guard let connection = cgsConnection, let copySpaces = cgsCopyManagedDisplaySpaces else {
        return []
    }
    let cid = connection()
    guard cid > 0 else { return [] }

    guard let entries = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
        return []
    }

    let byIdentifier = displayIDsByIdentifier()
    let parsed = entries.compactMap { entry -> ManagedDisplay? in
        guard let identifier = entry["Display Identifier"] as? String,
              let spaces = entry["Spaces"] as? [[String: Any]],
              let displayID = displayID(forIdentifier: identifier, in: byIdentifier)
        else { return nil }

        // Every Space the display reports, with the `type` kept rather than filtered on.
        var seenSpaceIDs = Set<Int32>()
        let parsed = spaces.compactMap { space -> ManagedSpace? in
            guard let id = (space["id64"] as? NSNumber)?.int32Value else { return nil }
            // The window server can briefly report the same Space twice while Mission Control
            // is reordering it. Keep the first position so the phone never draws two tiles for
            // one desktop during that transition.
            guard seenSpaceIDs.insert(id).inserted else { return nil }
            return ManagedSpace(
                id: id,
                isFullscreen: (space["type"] as? NSNumber)?.intValue == 4,
                pid: (space["pid"] as? NSNumber)?.int32Value
            )
        }
        guard !parsed.isEmpty else { return nil }

        let current = entry["Current Space"] as? [String: Any]
        let reported = (current?["id64"] as? NSNumber)?.int32Value
        let ids = parsed.map(\.id)
        let activeID = reported.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]

        return ManagedDisplay(displayID: displayID, identifier: identifier, spaces: parsed, activeID: activeID)
    }

    var seenDisplayIDs = Set<UInt32>()
    let unique = parsed.filter { seenDisplayIDs.insert($0.displayID).inserted }

    // Main first, then whatever order the window server listed the rest in.
    let main = CGMainDisplayID()
    return unique.filter { $0.displayID == main } + unique.filter { $0.displayID != main }
}

/// Reads every display's Spaces from the window server.
func readDisplaySpaces() -> [ManagedDisplay] {
    dispatchPrecondition(condition: .onQueue(.main))
    return readDisplays()
}

/// Switches to the adjacent Space in `direction`, wrapping at either end.
@discardableResult
func switchSpaceRelative(direction: SpaceDirection) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let displays = readDisplays()
    guard let display = displays.first(where: { $0.displayID == DisplayGeometry.pointerDisplayID() })
        ?? displays.first
    else { return false }
    // Desktops, not every Space: stepping "left" out of a desktop and into whatever fullscreen
    // application happens to sit beside it in the list is not a move anyone asked for, and the
    // list order is the window server's rather than the user's.
    let desktops = display.desktopIDs
    guard desktops.count > 1 else { return false }
    guard let current = desktops.firstIndex(of: display.activeID) else { return false }

    let next: Int
    switch direction {
    case .left:  next = current == 0 ? desktops.count - 1 : current - 1
    case .right: next = current == desktops.count - 1 ? 0 : current + 1
    }
    return performSwitch(display: display, spaceID: desktops[next])
}

/// Switches directly to the 1-based Space at `index` **on `display`**.
@discardableResult
func switchToSpace(
    display: UInt32,
    index: Int,
    report: (@Sendable (SpaceSwitchRoute) -> Void)? = nil
) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard cgsSetManagedDisplayCurrentSpace != nil else { return false }
    guard let target = readDisplays().first(where: { $0.displayID == display }) else { return false }

    let zeroIndex = index - 1
    let desktops = target.desktopIDs
    guard zeroIndex >= 0, zeroIndex < desktops.count else { return false }

    // Logged because "accepted but nothing moved" and "the desktop I asked for is not the one
    // the phone drew under that number" look identical from every other vantage point — the
    // window server says yes either way, and the screen simply stays where it was.
    let destination = desktops[zeroIndex]
    spaceLog.notice("""
        display \(display, privacy: .public): tile \(index, privacy: .public) \
        of \(desktops.count, privacy: .public) over \(desktops, privacy: .public), \
        on \(target.activeID, privacy: .public), going to \(destination, privacy: .public)
        """)

    if destination == target.activeID { return true }

    return performSwitch(display: target, spaceID: destination, report: report)
}

// MARK: - Windows on other desktops

private typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias WindowQueryFunc = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
private typealias WindowQueryResultFunc = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
private typealias IteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
private typealias IteratorUInt32Func = @convention(c) (CFTypeRef) -> UInt32
private typealias IteratorUInt64Func = @convention(c) (CFTypeRef) -> UInt64

private let copySpacesForWindows = resolve("SLSCopySpacesForWindows")
    .map { unsafeBitCast($0, to: CopySpacesForWindowsFunc.self) }
private let queryWindows = resolve("SLSWindowQueryWindows")
    .map { unsafeBitCast($0, to: WindowQueryFunc.self) }
private let queryResultWindows = resolve("SLSWindowQueryResultCopyWindows")
    .map { unsafeBitCast($0, to: WindowQueryResultFunc.self) }
private let iteratorAdvance = resolve("SLSWindowIteratorAdvance")
    .map { unsafeBitCast($0, to: IteratorAdvanceFunc.self) }
private let iteratorWindowID = resolve("SLSWindowIteratorGetWindowID")
    .map { unsafeBitCast($0, to: IteratorUInt32Func.self) }
private let iteratorParentID = resolve("SLSWindowIteratorGetParentID")
    .map { unsafeBitCast($0, to: IteratorUInt32Func.self) }
private let iteratorTags = resolve("SLSWindowIteratorGetTags")
    .map { unsafeBitCast($0, to: IteratorUInt64Func.self) }
private let iteratorAttributes = resolve("SLSWindowIteratorGetAttributes")
    .map { unsafeBitCast($0, to: IteratorUInt64Func.self) }

private func spaceIDs(ofWindow windowID: CGWindowID, connection: Int32) -> [Int32] {
    guard let copy = copySpacesForWindows,
          let spaces = copy(connection, 7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
            as? [NSNumber]
    else { return [] }
    return spaces.map(\.int32Value)
}

/// Of `windowIDs`, the ones ordered in on a Space: open, on some desktop, whether or not that
/// desktop is showing.
func windowsOrderedInOnSpaces(_ windowIDs: [CGWindowID]) -> Set<CGWindowID> {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !windowIDs.isEmpty,
          let connection = cgsConnection?(), connection > 0,
          let query = queryWindows, let results = queryResultWindows,
          let advance = iteratorAdvance, let windowID = iteratorWindowID,
          let parentID = iteratorParentID, let tags = iteratorTags, let attributes = iteratorAttributes,
          let queried = query(connection, windowIDs.map { NSNumber(value: $0) } as CFArray, Int32(windowIDs.count))?
            .takeRetainedValue(),
          let iterator = results(queried)?.takeRetainedValue()
    else { return [] }

    var found = Set<CGWindowID>()
    while advance(iterator) {
        guard parentID(iterator) == 0 else { continue }
        let tag = tags(iterator)
        let orderedIn = attributes(iterator) & 0x2 != 0 || tag & 0x400000000000000 != 0
        let isDocument = tag & 0x1 != 0 || (tag & 0x2 != 0 && tag & 0x80000000 != 0)
        guard orderedIn, isDocument else { continue }
        let id = windowID(iterator)
        if !spaceIDs(ofWindow: id, connection: connection).isEmpty { found.insert(id) }
    }
    return found
}

@discardableResult
func switchToSpace(holding windowID: CGWindowID) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let connection = cgsConnection?(), connection > 0 else { return false }
    let spaces = spaceIDs(ofWindow: windowID, connection: connection)
    for display in readDisplays() {
        guard let space = spaces.first(where: display.ids.contains) else { continue }
        guard !spaces.contains(display.activeID) else { return false }
        spaceLog.notice("window \(windowID, privacy: .public) is on space \(space, privacy: .public), going there")
        return performSwitch(display: display, spaceID: space)
    }
    return false
}

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
private func performSwitch(
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
        // unavailable, and it comes back *silently* — the switch still happens, only the
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
    // landed, and the direct setter is used — which is the stacked picture this whole route
    let pointerWas = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(spaceCentre(of: displayID))

    DispatchQueue.main.asyncAfter(deadline: .now() + chordApproachDelay) {
        postSpaceChord(approach.direction)

        if let pointerWas {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(chordKeyGapMilliseconds * 6)) {
                CGWarpMouseCursorPosition(pointerWas)
            }
        }

        // A chord that was dropped — the permission withdrawn mid-session, a Space removed
        // between the two reads — leaves the display sitting on the neighbour. Looked at once
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
