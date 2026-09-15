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

private let skyLight: UnsafeMutableRawPointer? = dlopen(
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
        let parsed = spaces.compactMap { space -> ManagedSpace? in
            guard let id = (space["id64"] as? NSNumber)?.int32Value else { return nil }
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

    // Main first, then whatever order the window server listed the rest in.
    let main = CGMainDisplayID()
    return parsed.filter { $0.displayID == main } + parsed.filter { $0.displayID != main }
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
/// Goes through the window server rather than posting ⌃←/⌃→, which is the difference between a
/// switch that happens and one that is swallowed: Mission Control's shortcuts are matched by the
/// window server, and synthetic key events posted at the HID tap do not reach that match.
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
func switchToSpace(display: UInt32, index: Int) -> Bool {
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

    return performSwitch(display: target, spaceID: destination)
}

private func performSwitch(display: ManagedDisplay, spaceID: Int32) -> Bool {
    guard let connection = cgsConnection, let setCurrent = cgsSetManagedDisplayCurrentSpace else {
        return false
    }
    let cid = connection()
    guard cid > 0 else { return false }
    // 0 is `kCGErrorSuccess`. Reported rather than assumed: a refused switch is the difference
    // between a tile that does nothing and a client that knows not to offer it.
    return setCurrent(cid, display.identifier as CFString, UInt64(spaceID)) == 0
}
