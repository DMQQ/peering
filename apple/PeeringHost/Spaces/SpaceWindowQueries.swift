import CoreGraphics
import Darwin
import Foundation
import os

private let spaceLog = Logger(subsystem: "pl.dmq.peering.host", category: "spaces")

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
