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
//
// **The names are `SLS*`, not `CGS*`, and asking for the wrong spelling is the whole reason this
// reader once returned nil on macOS 26.** SkyLight exports no `CGS*` symbol at all; CoreGraphics
// re-exports a subset of the SkyLight functions under the older `CGS*` names as aliases, which is
// why a probe that searched only the loaded images found `CGSCopyManagedDisplaySpaces` and not
// `CGSGetWorkspaceList` and drew the wrong conclusion from it. The functions behind the names this
// file used to call — `CGSGetWorkspaceList` and `CGSSetWorkspace` — genuinely have no successor
// under either spelling: they belong to the pre-10.9 model of one global list of workspaces, which
// was replaced by per-display Spaces. Everything below therefore asks for the `SLS` name first and
// keeps the `CGS` spelling as a fallback for a macOS that moves them back.
//
// `dlopen` first, `dlsym` second. Searching `RTLD_DEFAULT` alone only finds an image that happens
// to be loaded already, which makes "missing" and "not loaded yet" the same answer — the confusion
// the names above were rescued from. An explicit handle is also what keeps this working in a
// command-line probe, where AppKit has not dragged SkyLight in.

/// **`nonisolated(unsafe)`, and the promise being made here is a small one.**
///
/// `dlopen` hands back a pointer this file only ever reads, `let` binds it once, and `dlsym`
/// against a handle is documented as thread-safe. What Swift 6 objects to is the *type*: a raw
/// pointer is not `Sendable`, so a global holding one is shared mutable state as far as it can
/// tell. Marking the declaration is what keeps that judgement in one place, rather than leaving
/// it inside `resolve` where every Space call in the app would pass through it.
private nonisolated(unsafe) let skyLight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_NOW
)

/// Resolves `name` inside SkyLight, then in everything else already loaded.
///
/// The second search is not redundant: the `CGS` aliases live in CoreGraphics' export table, so a
/// spelling that SkyLight has dropped can still be answered by CoreGraphics. It is also the only
/// thing that would survive SkyLight being folded into another framework.
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
///
/// **Main first, deliberately.** `SLSMainConnectionID` is the window server's main connection and
/// answers with the same value on every thread; `SLSDefaultConnectionForThread` does not — called
/// off the main thread it returns a *different* connection, which is why the entry points below
/// stay pinned to the main queue rather than being relaxed once a connection getter was found.
/// A list read with one connection and a switch issued with another is not a pairing worth
/// discovering the hard way.
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

/// `SLSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)`. This is what replaced
/// `CGSSetWorkspace`, and it is not a rename: the old call switched a *global* workspace by index,
/// while this one names the display whose Spaces are being reordered and the Space to reveal on it.
private let cgsSetManagedDisplayCurrentSpace: SetCurrentSpaceFunc? = resolveFirst([
    "SLSManagedDisplaySetCurrentSpace",
    "CGSManagedDisplaySetCurrentSpace",
]).map { unsafeBitCast($0, to: SetCurrentSpaceFunc.self) }

/// One display's entry in the window server's per-display Space lists.
///
/// Not private: the capture side builds a ``SpaceDisplay`` out of one, and the wire carries
/// ``displayID`` rather than the UUID, which stays an implementation detail of this file.
/// One Space, as the window server describes it.
///
/// The `type` field is the reason this type exists. `0` is a desktop the user made; `4` is a
/// fullscreen application's own Space. Both are Spaces, both can be the one on screen, and they
/// are **not** interchangeable: you switch to a desktop, whereas a fullscreen Space belongs to
/// one application and is reachable by going back to that application. Handing the second to
/// the client as though it were the first produced a tile that looked like a desktop, was
/// sometimes marked current, and did something else entirely when tapped.
struct ManagedSpace: Sendable, Equatable {
    let id: Int32
    let isFullscreen: Bool
    /// The application owning a fullscreen Space, from the window server's `pid`.
    ///
    /// The only way to name one — a Space has a number and a UUID, and neither is a name.
    let pid: Int32?
}

struct ManagedDisplay {
    /// The `CGDirectDisplayID` this entry describes.
    let displayID: UInt32
    /// The display's UUID, as a string. This is the key `SLSManagedDisplaySetCurrentSpace` wants,
    /// and A-string-is-A-string: it is compared by value, not by instance.
    let identifier: String
    /// Every Space on this display, in order — desktops and fullscreen applications alike.
    ///
    /// The IDs are the point of this type existing at all. A Space's *number* is only its
    /// current position in the list — adding or removing a desktop renumbers every Space after
    /// it — so anything that remembers a Space has to remember its ID. A preview cache keyed by
    /// number would hand the client one desktop's picture under another desktop's number, which
    /// is a wrong answer that looks like a right one.
    let spaces: [ManagedSpace]
    let activeID: Int32

    var ids: [Int32] { spaces.map(\.id) }

    /// The desktops, in order. What the client is offered and what it may switch to.
    var desktopIDs: [Int32] { spaces.filter { !$0.isFullscreen }.map(\.id) }

    /// The 1-based position of the active Space **among the desktops**, or `nil` when this
    /// display is showing a fullscreen application.
    ///
    /// `nil` rather than a fallback, unlike before. Falling back to the first desktop while a
    /// fullscreen app is on screen would mark a desktop current that is not the one being
    /// looked at — the same lie in the other direction.
    var current: Int? {
        desktopIDs.firstIndex(of: activeID).map { $0 + 1 }
    }

    /// The fullscreen application being shown, when that is what is on this display.
    var fullscreen: ManagedSpace? {
        spaces.first { $0.isFullscreen && $0.id == activeID }
    }
}

/// Every display's UUID, by the `CGDirectDisplayID` it belongs to.
///
/// Built by hand because the mapping only exists in one direction: `CGDisplayCreateUUIDFromDisplayID`
/// goes id → UUID, and the window server names displays the other way round. Only displays that
/// are actually drawing are asked about — a sleeping display has no Spaces to name.
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

/// The display ID behind a window server display UUID, or `nil` if no drawing display claims it.
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
///
/// **Every display, and in this order.** Spaces are per-display and the window server reports one
/// ordered list for each, so a reader that returned only one of them could describe at most one
/// screen's desktops — which is what this used to do, always the main display, leaving a second
/// screen's desktops invisible to the client even though the window server had them all along.
/// Main first because callers that predate multiple displays read the first entry as "the"
/// display, and that keeps meaning what it always did.
///
/// The active Space is read from each display's own `Current Space` entry rather than from
/// `SLSGetActiveSpace`, which reports only whichever display the user is focused on. Reading it
/// here keeps `activeID` inside `ids` by construction, which is what
/// ``orderedSpacePreviews(ids:activeID:shots:)`` checks before it will emit a single preview.
private func readDisplays() -> [ManagedDisplay] {
    guard let connection = cgsConnection, let copySpaces = cgsCopyManagedDisplaySpaces else {
        return []
    }
    let cid = connection()
    guard cid > 0 else { return [] }

    // `Copy` rule: the array is ours and ARC would not know to release it.
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
        //
        // The type is not discarded here for the reason it used to be dropped entirely: a
        // fullscreen Space is the active one whenever a window is fullscreen, so a reader that
        // only knew desktops would report an `activeID` it could not find — and an `activeID`
        // outside the list costs the client *every* preview on that display, not one tile.
        // Keeping it and *labelling* it means the list stays complete and the caller can still
        // tell a place it may be sent from an application it may only return to.
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

    // Mirrored and recently detached screens can briefly arrive as two entries that resolve to
    // the same CGDirectDisplayID. SwiftUI keys display rows by that ID, so letting both through
    // produces a duplicated row and unstable identity. Preserve the first complete entry.
    var seenDisplayIDs = Set<UInt32>()
    let unique = parsed.filter { seenDisplayIDs.insert($0.displayID).inserted }

    // Main first, then whatever order the window server listed the rest in.
    let main = CGMainDisplayID()
    return unique.filter { $0.displayID == main } + unique.filter { $0.displayID != main }
}

/// Reads every display's Spaces from the window server.
///
/// Returns an empty array if the private API is unavailable — callers should treat that as
/// "unknown" and hide the Space picker rather than show stale data.
///
/// **Must be called on the main thread.** Both connection getters above are thread-sensitive:
/// the one this reader prefers is stable, but the fallbacks are not, and which one gets used is
/// not something a caller can see. Pinning every entry point to the main queue makes the
/// connection a given rather than a race.
func readDisplaySpaces() -> [ManagedDisplay] {
    dispatchPrecondition(condition: .onQueue(.main))
    return readDisplays()
}

/// Switches to the adjacent Space in `direction`, wrapping at either end.
///
/// Acts on **the display the pointer is on**, not the main one: macOS' own ⌃←/⌃→ reorder the
/// screen the user is looking at, and a relative switch that always moved the built-in display's
/// desktops would be wrong every time attention was on a second screen.
///
/// The move itself goes through ``performSwitch``, like every other one, and that is where the
/// working route is written down. Briefly: posting ⌃←/⌃→ with `CGEvent` is swallowed before it
/// reaches the window server's hot key match, so the desktop is jumped to directly and then
/// stepped onto with a chord posted through the Accessibility subsystem — which is the only
/// route the window server acts on.
///
/// Relative to the Space the display reports as current, so a switch that raced a user-driven one
/// moves from where the user actually is rather than from where this process last looked.
@discardableResult
func switchSpaceRelative(direction: SpaceDirection) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let displays = readDisplays()
    // `readDisplays` puts the main display first, so the fallback here is the main display.
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
///
/// The display is part of the request because Spaces are per-display: the same index 1 names a
/// different desktop on each screen, so an index alone cannot say which one to reveal.
///
/// Returns whether the window server accepted the switch. Fails silently if the private API is
/// unavailable, the display is gone, or the index is out of range — callers should not surface an
/// error for a missing Space because the user might have removed it since the catalogue was sent.
@discardableResult
func switchToSpace(
    display: UInt32,
    index: Int,
    report: (@Sendable (SpaceSwitchRoute) -> Void)? = nil
) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard cgsSetManagedDisplayCurrentSpace != nil else { return false }
    // A fresh read on every switch, for the same reason the reader is a read rather than a
    // cached value: between the catalogue being sent and the user tapping a tile, a desktop can
    // be added, removed or reordered, and an index resolved against the list the client was
    // shown would then name a different desktop.
    guard let target = readDisplays().first(where: { $0.displayID == display }) else { return false }

    let zeroIndex = index - 1
    // Against the desktops the client was shown, so index N means the Nth tile — which is what
    // it looks like it means. Counting every Space instead would put a fullscreen application
    // at some index, and the client has no tile for it to have been aiming at.
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

    return performSwitch(display: target, spaceID: destination, report: report)
}

// MARK: - Making the picture follow the switch

/// `AXUIElementPostKeyboardEvent`, which is the only route by which a simulated ⌃←/⌃→ reaches
/// the window server's symbolic hot key match.
///
/// **The obvious ways do not work, and finding that out is why this file is shaped the way it
/// is.** A chord posted with `CGEvent` is swallowed at every tap — `.cghidEventTap`,
/// `.cgSessionEventTap`, `.cgAnnotatedSessionEventTap`, with `.hidSystemState` and
/// `.combinedSessionState` sources, and addressed straight at the Dock's process with
/// `postToPid`. All of them leave the display exactly where it was. The window server matches
/// symbolic hot keys against events that arrived through the Accessibility subsystem, which is
/// why an assistive tool's keystroke works and a synthesised chord does not.
///
/// Resolved by name rather than linked, like the SkyLight calls above and for a different
/// reason: the SDK declares this `CF_DEPRECATED_MAC(10_0, 10_9)`, and **Swift refuses outright
/// to import an API deprecated before 10.9**. HIServices still exports it and it still works.
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
///
/// Both halves have to hold, and the second is the one that bites: without the Accessibility
/// permission the ask is dropped in silence, and a dropped chord leaves the display on the Space
/// *beside* the one that was asked for — a wrong desktop, which is worse than a stale picture.
/// So this route is offered only when the permission is actually held, and every caller falls
/// back to the direct call when it is not.
private var canPostSpaceChords: Bool {
    postKeyboardEvent != nil && AXIsProcessTrusted()
}

/// The virtual key codes of the one chord this file posts. `59` is the left control key; the
/// arrows are the codes the rest of the input path already uses.
private let chordControlKeyCode: CGKeyCode = 59
private let chordLeftKeyCode: CGKeyCode = 123
private let chordRightKeyCode: CGKeyCode = 124

/// How long the jump is given before the chord steps off it.
///
/// Measured rather than guessed: 150ms still lands cleanly on the desktop asked for, and the
/// shorter it is the less of the un-recomposited picture there is to see in between. A chord
/// posted before the window server has taken the jump steps from the Space we were on, and
/// lands beside the destination rather than on it.
private let chordApproachDelay = DispatchTimeInterval.milliseconds(150)

/// The gap between the four key events of a chord, and why there is one: a chord whose events
/// arrive as a single burst is not something a keyboard produces, and it is matched accordingly.
private let chordKeyGapMilliseconds = 25

/// Posts ⌃←/⌃→, spread over the main queue.
///
/// Deliberately not a loop with sleeps between the events. Four Accessibility round trips with
/// pauses in them, run inline, is a visible stall in the host's window — and this happens while
/// someone is waiting to see a desktop appear.
/// The middle of a display, in the global coordinates a pointer position is expressed in.
///
/// The middle rather than a corner, because a chord acts on whichever display holds the pointer
/// and the centre is the one point that cannot be outside the display it is the centre of.
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
///
/// A named function rather than the call written inline at the loop above, and that is a
/// concurrency requirement rather than a style one: the scheduled closure is `@Sendable`, and
/// capturing the resolved function pointer — or the system-wide element — inside it is a data
/// race as far as Swift 6 is concerned. Calling a function captures nothing, and the element is
/// made fresh here, which costs nothing.
private func postKeyEvent(_ key: CGKeyCode, down: Bool) {
    guard let post = postKeyboardEvent else { return }
    _ = post(AXUIElementCreateSystemWide(), 0, key, down)
}

/// The Space to jump to, and the way to step off it onto `spaceID`.
///
/// **The neighbour is the adjacent entry in the window server's whole Space list, not the
/// adjacent desktop.** A fullscreen application's Space sits in that list too, and a chord steps
/// into and out of those, so taking the neighbouring *desktop* would leave a fullscreen Space
/// between the jump and the step — and the chord would land on that instead.
///
/// `nil` when the chord route cannot be used, which sends the caller back to the direct call:
/// a Mac without the Accessibility permission, a display with only one Space, and — the case
/// that matters — a display that is not the one the pointer is on.
private func chordApproach(
    display: ManagedDisplay, spaceID: Int32
) -> ChordApproach {
    guard canPostSpaceChords else { return .unusable(.noPermission) }
    // A chord acts on the display the pointer is on. With one screen that is always this one;
    // with two, jumping this display and then stepping would move the other one.
    guard display.displayID == DisplayGeometry.pointerDisplayID() else {
        return .unusable(.pointerElsewhere)
    }

    let spaces = display.spaces
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
        return .unusable(.noApproach)
    }
    // The Space before it, stepping forward; or, for the first Space in the list, the one after
    // it, stepping back. Both land on the destination in a single step.
    if index > 0 { return .step(neighbour: spaces[index - 1].id, direction: .right) }
    if index < spaces.count - 1 { return .step(neighbour: spaces[index + 1].id, direction: .left) }
    return .unusable(.noApproach)
}

/// The outcome of ``chordApproach(display:spaceID:)``: somewhere to step from, or the reason
/// there is not.
private enum ChordApproach {
    case step(neighbour: Int32, direction: SpaceDirection)
    case unusable(SpaceSwitchRoute.DirectReason)
}

/// The direct call on its own: instant, and correct only as the approach to a real transition.
///
/// 0 is `kCGErrorSuccess`. Reported rather than assumed: a refused switch is the difference
/// between a tile that does nothing and a client that knows not to offer it.
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
///
/// **A switch that took the direct route is not a switch that worked**, and until this existed the
/// two were indistinguishable from outside this file. The window server accepts both, the desktop
/// changes both times, and only the picture gives the difference away, seconds later and on the
/// phone rather than here.
enum SpaceSwitchRoute: Sendable, Equatable {
    /// The chord stepped onto the destination: a real transition, so the compositor redid the
    /// picture.
    case chord
    /// The window server was told directly. The Space moves, and the display can go on compositing
    /// the desktop that was there before with the arriving one's windows over it.
    case direct(DirectReason)
    /// The window server would not move the display at all, by either route.
    case refused

    enum DirectReason: Sendable, Equatable {
        /// No Accessibility permission, so a posted chord is dropped in silence.
        case noPermission
        /// The pointer is on another display, and a chord acts on the one it is on.
        case pointerElsewhere
        /// The chord was posted and the display did not move.
        case chordDidNotLand
        /// Nowhere to step from: one Space, or the window server would not make the neighbour
        /// current.
        case noApproach
    }
}

/// Moves `display` onto `spaceID`, **and makes the picture follow it.**
///
/// **The direct call on its own is not enough, and this is the bug it caused.** Setting the
/// current Space updates what the window server *considers* current without running the window
/// show/hide cycle the Dock performs during a real transition. The display keeps compositing the
/// desktop that was left, with the arriving one's windows drawn over and around it: every desktop
/// stacked on the last. It failed about half the time and deterministically per transition rather
/// than at random, and it is **not something this app causes** — it reproduces with the host not
/// running at all, which is what ruled out the capture stream.
///
/// **Nothing repairs it afterwards.** A second call to the setter, a mouse move, hiding and
/// showing the cursor, a display reconfiguration, and making and destroying a window were all
/// tried, and all left the stale picture in place. Only a real transition clears it, which is why
/// someone at the Mac can fix it by hand by switching desktops and clicking around.
///
/// So: **jump to the Space beside the destination, then step onto it with a real chord.** The
/// jump is instant, so a distant desktop is not walked to a slide at a time, and it leaves the
/// same stale picture it always does; the chord that follows is a genuine transition, and redoing
/// the composite is exactly what clears the mess. One short slide is the cost, where the switch
/// used to be instant.
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
    // exists to avoid. Measured on a two-display Mac, every switch took that path.
    let pointerWas = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(spaceCentre(of: displayID))

    DispatchQueue.main.asyncAfter(deadline: .now() + chordApproachDelay) {
        postSpaceChord(approach.direction)

        // Back where it was once the chord has been posted rather than immediately: the four
        // events go out over the next few dozen milliseconds, and the display each of them is
        // matched against is read as it arrives.
        if let pointerWas {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(chordKeyGapMilliseconds * 6)) {
                CGWarpMouseCursorPosition(pointerWas)
            }
        }

        // A chord that was dropped — the permission withdrawn mid-session, a Space removed
        // between the two reads — leaves the display sitting on the neighbour. Looked at once
        // the slide would have finished, and only corrected if that is still where it is: if
        // the Space has moved anywhere else then somebody else moved it, and putting it back
        // would be fighting the person using the Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700)) {
            guard let now = readDisplays().first(where: { $0.displayID == displayID }),
                  now.activeID == approach.neighbour
            else {
                // Moved, so the chord landed and the composite was redone with it.
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
