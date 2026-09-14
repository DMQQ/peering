import ColorSync
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import RemoteCore

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

/// The Spaces as the window server holds them: every desktop's ID in display order, and which
/// of them is active.
///
/// The IDs are the point of this type existing at all. A Space's *number* is only its current
/// position in the list — adding or removing a desktop renumbers every desktop after it — so
/// anything that remembers a desktop has to remember its ID. A preview cache keyed by number
/// would hand the client one desktop's picture under another desktop's number, which is a
/// wrong answer that looks like a right one.
struct SpaceList: Sendable, Equatable {
    let ids: [Int32]
    let activeID: Int32

    /// The 1-based position of the active Space, in the numbering clients are sent.
    ///
    /// Falls back to the first Space when the ID is not in the list, which is what a switch
    /// landing between the two reads below looks like from here.
    var current: Int {
        ids.firstIndex(of: activeID).map { $0 + 1 } ?? 1
    }
}

/// One display's entry in the window server's per-display Space lists.
private struct ManagedDisplay {
    /// The display's UUID, as a string. This is the key `SLSManagedDisplaySetCurrentSpace` wants,
    /// and A-string-is-A-string: it is compared by value, not by instance.
    let identifier: String
    let ids: [Int32]
    let activeID: Int32
}

/// The main display's Spaces.
///
/// **The main display, not every display.** Spaces are per-display, and the window server reports
/// one ordered list for each. Preview capture photographs `CGMainDisplayID()` — see
/// ``ScreenCaptureSourceResolver.captureActiveSpacePreview()`` — so a list drawn from any other
/// display would number desktops that can never hold a picture, and would file a photograph of the
/// main display's desktop under a different display's Space ID. The two have to agree, and the
/// capture side is the one that cannot move.
///
/// The active Space is read from the display's own `Current Space` entry rather than from
/// `SLSGetActiveSpace`, which reports whichever display the user is focused on. Reading it here
/// keeps `activeID` inside `ids` by construction, which is what ``orderedSpacePreviews(ids:activeID:shots:)``
/// checks before it will emit a single preview.
private func readMainDisplay() -> ManagedDisplay? {
    guard let connection = cgsConnection, let copySpaces = cgsCopyManagedDisplaySpaces else {
        return nil
    }
    let cid = connection()
    guard cid > 0 else { return nil }

    // `Copy` rule: the array is ours and ARC would not know to release it.
    guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
        return nil
    }

    let mainUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()).takeRetainedValue()
    let mainIdentifier = CFUUIDCreateString(nil, mainUUID) as String

    guard let display = displays.first(where: { $0["Display Identifier"] as? String == mainIdentifier }),
          let spaces = display["Spaces"] as? [[String: Any]]
    else {
        return nil
    }

    // Every Space the display reports, with no filter on `type`.
    //
    // Tempting to keep only the user Spaces (`type` 0) and drop the fullscreen ones (`type` 4),
    // and wrong: a fullscreen Space is the active one whenever a window is fullscreen, so
    // filtering would drop the ID this list reports as current, and an `activeID` outside `ids`
    // costs the client *every* preview — not one tile — because the whole preview set is
    // discarded when the list and the active Space disagree.
    let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.int32Value }
    guard !ids.isEmpty else { return nil }

    let current = display["Current Space"] as? [String: Any]
    let reported = (current?["id64"] as? NSNumber)?.int32Value
    let activeID = reported.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]

    return ManagedDisplay(identifier: mainIdentifier, ids: ids, activeID: activeID)
}

/// Reads the Space IDs and the active one from the window server.
///
/// Returns `nil` if the private API is unavailable — callers should treat `nil` as "unknown"
/// and hide the Space picker rather than show stale data.
///
/// **Must be called on the main thread.** Both connection getters above are thread-sensitive:
/// the one this reader prefers is stable, but the fallbacks are not, and which one gets used is
/// not something a caller can see. Pinning every entry point to the main queue makes the
/// connection a given rather than a race.
func readSpaceList() -> SpaceList? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let display = readMainDisplay() else { return nil }
    return SpaceList(ids: display.ids, activeID: display.activeID)
}

/// Reads the current Space count and active Space index from the window server.
///
/// The same read as ``readSpaceList()`` with the IDs dropped. Callers that only need what the
/// picker shows want this one; anything that has to remember a desktop across a renumbering
/// wants the list.
///
/// Previews are not read here and cannot be: they belong to ``SpacePreviewCache``, which needs
/// a screenshot to have been taken off this thread first.
///
/// Inherits the main-thread requirement from ``readSpaceList()``.
func readSpaceInfo() -> SpaceInfo? {
    guard let list = readSpaceList() else { return nil }
    return SpaceInfo(count: list.ids.count, current: list.current)
}

/// Switches to the adjacent Space in `direction`, wrapping at either end.
///
/// Goes through the window server rather than posting ⌃←/⌃→, which is the difference between a
/// switch that happens and one that is swallowed: Mission Control's shortcuts are matched by the
/// window server, and synthetic key events posted at the HID tap do not reach that match.
///
/// Relative to the Space the list reports as current, so a switch that raced a user-driven one
/// moves from where the user actually is rather than from where this process last looked.
@discardableResult
func switchSpaceRelative(direction: SpaceDirection) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let display = resolveSwitchTarget() else { return false }
    guard display.ids.count > 1 else { return false }
    guard let current = display.ids.firstIndex(of: display.activeID) else { return false }

    let next: Int
    switch direction {
    case .left:  next = current == 0 ? display.ids.count - 1 : current - 1
    case .right: next = current == display.ids.count - 1 ? 0 : current + 1
    }
    return performSwitch(display: display, spaceID: display.ids[next])
}

/// Switches directly to the 1-based Space at `index`.
///
/// Returns whether the window server accepted the switch. Fails silently if the private API is
/// unavailable or the index is out of range — callers should not surface an error for a missing
/// Space because the user might have removed it since the catalog was sent.
@discardableResult
func switchToSpace(index: Int) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let display = resolveSwitchTarget() else { return false }
    let zeroIndex = index - 1
    guard zeroIndex >= 0, zeroIndex < display.ids.count else { return false }
    return performSwitch(display: display, spaceID: display.ids[zeroIndex])
}

/// The display a switch will act on.
///
/// A fresh read on every switch, for the same reason the reader is a read rather than a cached
/// value: between the catalogue being sent and the user tapping a tile, a desktop can be added,
/// removed or reordered, and an index resolved against the list the client was shown would then
/// name a different desktop.
private func resolveSwitchTarget() -> ManagedDisplay? {
    guard cgsSetManagedDisplayCurrentSpace != nil else { return nil }
    return readMainDisplay()
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
