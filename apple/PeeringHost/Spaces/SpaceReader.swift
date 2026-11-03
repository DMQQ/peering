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
func resolve(_ name: String) -> UnsafeMutableRawPointer? {
    if let handle = skyLight, let symbol = dlsym(handle, name) { return symbol }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private func resolveFirst(_ names: [String]) -> UnsafeMutableRawPointer? {
    for name in names {
        if let symbol = resolve(name) { return symbol }
    }
    return nil
}

typealias ConnectionFunc = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SetCurrentSpaceFunc = @convention(c) (Int32, CFString, UInt64) -> Int32

/// The connection every call below shares.
let cgsConnection: ConnectionFunc? = resolveFirst([
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

let cgsSetManagedDisplayCurrentSpace: SetCurrentSpaceFunc? = resolveFirst([
    "SLSManagedDisplaySetCurrentSpace",
    "CGSManagedDisplaySetCurrentSpace",
]).map { unsafeBitCast($0, to: SetCurrentSpaceFunc.self) }

/// One display's entry in the window server's per-display Space lists.
struct ManagedSpace: Sendable, Equatable {
    let id: Int32
    let isFullscreen: Bool
    /// The application owning a fullscreen Space, from the window server's `pid`.
    ///
    /// The only way to name one, a Space has a number and a UUID, and neither is a name.
    let pid: Int32?
}

struct ManagedDisplay {
    let displayID: UInt32
    let identifier: String
    /// Every Space on this display, in order, desktops and fullscreen applications alike.
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
func readDisplays() -> [ManagedDisplay] {
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

    let desktops = target.desktopIDs
    guard index >= 1, index <= desktops.count else { return false }
    let zeroIndex = index - 1

    // Logged because "accepted but nothing moved" and "the desktop I asked for is not the one
    // the phone drew under that number" look identical from every other vantage point, the
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
