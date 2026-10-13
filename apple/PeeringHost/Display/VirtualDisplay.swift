import CoreGraphics
import Foundation
import PeeringKit
import os

private let virtualDisplayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A software monitor shaped like the phone, offered as an ordinary CaptureSource/display(_:).
/// Private API (CGVirtualDisplay, no header), host-only: the DMG is notarised outside the App Store, but Peering, PeeringKit and RemoteCore must never reach for it.
/// Differences from the widely copied header, read back with class_copyMethodList on macOS 27:
/// - setTerminalID: does not exist; sending it raises an uncatchable NSException. The field is setSerialNumber:.
/// - hiDPI does not make a display denser (1720x3728 with an 860x1864 mode came back as 1x points). The mode is the size.
/// - There is no alloc: initWithDescriptor: allocates and initialises, and the result is the display lifetime.
/// The display lives exactly as long as this object, so any other strong reference (a proxy, a captured closure, a lazy property) leaves a monitor the user cannot remove.
final class VirtualDisplay {
    enum Failure: LocalizedError {
        case unavailable
        case refused(CGSize)

        var errorDescription: String? { message.englishText }

        var message: LocalizedStringResource {
            switch self {
            case .unavailable:
                "This Mac's system software does not have the virtual display API."
            case .refused(let size):
                "The system refused a \(Int(size.width))×\(Int(size.height)) virtual display."
            }
        }
    }

/// Points equal pixels on purpose: the stream is sized from CGDisplayPixelsWide, which on Retina answers in points, so a 2x backing would stream at half its pixels. At 1x it arrives at 1290x2796, pixel for pixel.
/// A default, since the switch is thrown whether or not a phone is connected. init(size:name:startLandscape:) defaults to landscape, which suits working on it.
    static let phoneShaped = CGSize(width: 1290, height: 2796)

/// Asked before the switch is offered, so a macOS that removes the class shows a switch that says so; a lookup, not a probe.
    static var isAvailable: Bool {
        descriptorClass != nil && displayClass != nil && settingsClass != nil && modeClass != nil
    }

    let displayID: CGDirectDisplayID

/// Portrait first regardless of start orientation; setOrientation(landscape:) switches between exactly these two pixel sizes.
    private let portraitPixelSize: CGSize
    private let landscapePixelSize: CGSize

/// So a repeated report of the same orientation is not a second mode switch.
    private(set) var isLandscape: Bool

/// Advisory, never a reason to throw: CGGetActiveDisplayList can report only the built-in panel for the whole wait while the display is already real.
    let appearedInList: Bool

/// AnyObject because the class is in no header the compiler can see.
    private var display: AnyObject?

/// NSScreen cannot be relied on to adopt a virtual display (a process that read NSScreen.screens before it existed never sees it), so without this the catalogue would offer it as Display 13.
    private static let names = DisplayNames()

    static func name(for displayID: CGDirectDisplayID) -> String? {
        names.name(for: displayID)
    }

    /// Excludes the Mac settings switch display, so it does not consume one of the three extra slots or grow rename/remove controls that could disagree with the switch.
    static func isPhoneManaged(_ displayID: CGDirectDisplayID) -> Bool {
        names.isPhoneManaged(displayID)
    }

    /// No live rename exists on CGVirtualDisplay (setName: is descriptor-only), so this only changes the registry; NSScreen never adopts a virtual display, so the registry is the only name the catalogue reads.
    static func rename(_ displayID: CGDirectDisplayID, to name: String) {
        names.record(displayID, name: name)
    }

/// size is always read as portrait: setOrientation(landscape:) switches between the two modes registered on this one display. Throws only if the window server refuses the display; appearedInList is reported, not judged. A failure releases what was made.
    init(
        size: CGSize = VirtualDisplay.phoneShaped,
        name: String = "Peering Phone Display",
        startLandscape: Bool = true,
        serialNumber: UInt32 = 1,
        productID: UInt32 = 0x5045,
        isPhoneManaged: Bool = false
    ) throws {
        guard let descriptorClass = Self.descriptorClass,
              let displayClass = Self.displayClass,
              let settingsClass = Self.settingsClass,
              let modeClass = Self.modeClass
        else { throw Failure.unavailable }

// Built here, not as lazy statics: a static holding a bitcast of a missing class would pass nil to initWithDescriptor: and crash far from the cause.
        let displayFactory = unsafeBitCast(displayClass, to: DisplayCreating.Type.self)
        let modeFactory = unsafeBitCast(modeClass, to: ModeCreating.Type.self)

        let portraitWidth = UInt32(max(2, size.width.rounded(.down)))
        let portraitHeight = UInt32(max(2, size.height.rounded(.down)))
        let portrait = CGSize(width: CGFloat(portraitWidth), height: CGFloat(portraitHeight))
        let landscape = CGSize(width: CGFloat(portraitHeight), height: CGFloat(portraitWidth))
        self.portraitPixelSize = portrait
        self.landscapePixelSize = landscape

        let descriptorObject = descriptorClass.init()
        let descriptor = unsafeBitCast(descriptorObject, to: DescriptorWriting.self)
        descriptor.put(queue: .main)
        descriptor.put(name: name as NSString)
// The ceiling either mode may be asked for (the longer side), so a rotation is a mode switch and never a resize past the described panel.
        let longSide = max(portraitWidth, portraitHeight)
        descriptor.put(maxPixelsWide: longSide)
        descriptor.put(maxPixelsHigh: longSide)
// Physical size is cosmetic and measured as ignored, but a descriptor missing a documented field can fail to appear at all.
        descriptor.put(sizeInMillimeters: Self.millimetres(for: portrait))
// Identity: fixed serial/product keep the lone display recognisable across launches; callers making several pass distinct pairs, because serials alone reset every panel to 800x600 while distinct products preserve the modes. See HostModel+VirtualDisplayManagement.swift.
        descriptor.put(serialNumber: serialNumber)
        descriptor.put(productID: productID) // 0x5045 is "PE", and the first display's own number.
        descriptor.put(vendorID: 0x646D)  // "dm", this developer's prefix

        let displayObject = displayFactory.init(descriptor: descriptorObject)

        let settingsObject = settingsClass.init()
        let settings = unsafeBitCast(settingsObject, to: SettingsWriting.self)
// The mode is the whole size (see hiDPI above); 60 Hz because a phone cannot show more. The starting mode comes first and is forced again below.
        let portraitMode = modeFactory.init(width: portraitWidth, height: portraitHeight, refreshRate: 60)
        let landscapeMode = modeFactory.init(width: portraitHeight, height: portraitWidth, refreshRate: 60)
        settings.put(modes: startLandscape ? [landscapeMode, portraitMode] : [portraitMode, landscapeMode])

        let proxy = unsafeBitCast(displayObject, to: DisplayReading.self)
        let applied = proxy.apply(settings: settingsObject)
// In a local because a property read in the log closure needs self. in an initialiser.
        let id = proxy.displayID()
        displayID = id
        guard applied, id != 0 else { throw Failure.refused(size) }

// The window server takes the display asynchronously, so this polls for up to three seconds (it takes hundreds of milliseconds).
        appearedInList = Self.waitForAppearance(of: displayID)
        if !appearedInList {
            let listed = Self.activeDisplayIDs().map(String.init).joined(separator: ",")
            virtualDisplayLog.notice("""
                virtual display \(id, privacy: .public) was accepted by the window server; this \
                process lists only \(listed, privacy: .public)
                """)
        }

        self.display = displayObject
        self.isLandscape = startLandscape
        Self.names.record(id, name: name, isPhoneManaged: isPhoneManaged)
// Forced because this call is documented to select the current mode, and a later rotation uses the same route.
        if appearedInList { _ = restoreCurrentMode() }
// Placed explicitly: the window server puts the new panel below the built-in display, off the arrangement most people scroll to, which reads as never made. To the right of existing displays, top-aligned.
        if appearedInList { Self.placeBesideExistingDisplays(id) }
        let origin = CGDisplayBounds(id).origin
        let active = startLandscape ? landscape : portrait
        virtualDisplayLog.notice("""
            virtual display \(id, privacy: .public) on screen at \
            \(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public) · \
            \(Int(active.width), privacy: .public)×\(Int(active.height), privacy: .public) pixels
            """)
    }

/// Dropping the reference is the whole teardown; the poll exists because removal is asynchronous. A false is logged, not retried: there is no second reference to drop.
    @discardableResult
    func remove() -> Bool {
        // Before the reference is dropped: once the display is gone a pointer on it sits at a coordinate no screen occupies. See bringPointerBack(from:).
        Self.bringPointerBack(from: CGDisplayBounds(displayID))
// Not bound: a guard let would hold a second strong reference, so the release below would not be the release.
        guard display != nil else {
            let gone = !Self.activeDisplayIDs().contains(displayID)
            if gone { Self.names.forget(displayID) }
            return gone
        }
        self.display = nil

        let gone = Self.waitForDeparture(of: displayID)
        if gone {
            Self.names.forget(displayID)
            virtualDisplayLog.notice("virtual display \(self.displayID, privacy: .public) removed")
        } else {
            virtualDisplayLog.error("""
                virtual display \(self.displayID, privacy: .public) was released and is still on \
                screen; the window server did not let go of it
                """)
        }
        return gone
    }

    /// Called from remove(): a pointer left on the vanished display is one the user cannot find. CGWarpMouseCursorPosition, not a synthetic move, and the main display because it has the menu bar and so can never be one this app made.
    private static func bringPointerBack(from bounds: CGRect) {
        guard !bounds.isEmpty,
              let pointer = CGEvent(source: nil)?.location,
              bounds.contains(pointer)
        else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        guard !main.isEmpty else { return }
        CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY))
        virtualDisplayLog.notice("pointer brought back from a virtual display")
    }

/// A second registered mode is not a second display. Recreating the display for a rotation would trip the identity trap: this Mac refuses a second display sharing vendor, product and serial.
/// Returns whether the window server accepted the switch; repeating the current orientation returns true without asking, so per-layout-pass reports do not reconfigure the display.
    @discardableResult
    func setOrientation(landscape: Bool) -> Bool {
        guard landscape != isLandscape else { return true }
        guard display != nil else { return false }
        guard Self.applyMode(displayID, size: landscape ? landscapePixelSize : portraitPixelSize) else {
            return false
        }
        isLandscape = landscape
        virtualDisplayLog.notice("""
            virtual display \(self.displayID, privacy: .public) rotated to \
            \(landscape ? "landscape" : "portrait", privacy: .public)
            """)
        return true
    }

    /// Creating another CGVirtualDisplay can reset existing panels to 800x600 though their modes remain. Polls briefly because the display can appear before its mode list does, which otherwise makes this a silent no-op.
    @discardableResult
    func restoreCurrentMode() -> Bool {
        guard display != nil else { return false }
        let size = isLandscape ? landscapePixelSize : portraitPixelSize
        return Self.wait(timeout: 1) { Self.applyMode(displayID, size: size) }
    }

/// Public API on purpose: the one step of rotation with a documented entry point.
    private static func applyMode(_ displayID: CGDirectDisplayID, size: CGSize) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let target = modes.first(where: {
                  $0.pixelWidth == Int(size.width) && $0.pixelHeight == Int(size.height)
              })
        else { return false }
        return CGDisplaySetDisplayMode(displayID, target, nil) == CGError.success
    }

/// others excludes displayID, so the first virtual display lands beside the built-in panel and later ones beside the previous. With nothing else active the origin is left alone.
    private static func placeBesideExistingDisplays(_ displayID: CGDirectDisplayID) {
        let others = activeDisplayIDs().filter { $0 != displayID }
        guard !others.isEmpty else { return }
        let bounds = others.map(CGDisplayBounds)
        let rightEdge = bounds.map(\.maxX).max() ?? 0
        let top = bounds.map(\.minY).min() ?? 0

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(rightEdge), Int32(top))
        // .forSession, not .permanently: a permanent entry would leave a phantom arrangement once the display is gone.
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // MARK: - The window server's view

/// CGGetActiveDisplayList, not NSScreen.screens: a virtual display may or may not be in AppKit's list.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func waitForAppearance(of displayID: CGDirectDisplayID, timeout: TimeInterval = 3) -> Bool {
        wait(timeout: timeout) { activeDisplayIDs().contains(displayID) }
    }

    private static func waitForDeparture(of displayID: CGDirectDisplayID, timeout: TimeInterval = 3) -> Bool {
        wait(timeout: timeout) { !activeDisplayIDs().contains(displayID) }
    }

/// On the main thread the run loop is turned, not slept: the window server waits for the main run loop to answer a display change, which a sleeping thread cannot do.
    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return condition()
    }

/// 460 ppi; only the descriptor's bookkeeping uses it.
    private static func millimetres(for size: CGSize) -> CGSize {
        let millimetresPerPixel = 25.4 / 460
        return CGSize(width: size.width * millimetresPerPixel, height: size.height * millimetresPerPixel)
    }

    // MARK: - The private classes

    private static let descriptorClass: NSObject.Type? = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type
    private static let settingsClass: NSObject.Type? = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
    private static let displayClass: AnyClass? = NSClassFromString("CGVirtualDisplay")
    private static let modeClass: AnyClass? = NSClassFromString("CGVirtualDisplayMode")
}

/// Declared to match macOS 27, with unsigned int fields to match the class.
/// Reached by unsafeBitCast, not a cast: as? runs a conformance check a private class fails, so it would answer nil. Nothing checks signatures, so a renamed selector is a crash.
@objc private protocol DescriptorWriting: AnyObject {
    @objc(setQueue:) func put(queue: DispatchQueue)
    @objc(setName:) func put(name: NSString)
    @objc(setMaxPixelsWide:) func put(maxPixelsWide: UInt32)
    @objc(setMaxPixelsHigh:) func put(maxPixelsHigh: UInt32)
    @objc(setSizeInMillimeters:) func put(sizeInMillimeters: CGSize)
    @objc(setSerialNumber:) func put(serialNumber: UInt32)
    @objc(setProductID:) func put(productID: UInt32)
    @objc(setVendorID:) func put(vendorID: UInt32)
}

@objc private protocol SettingsWriting: AnyObject {
    @objc(setModes:) func put(modes: NSArray)
}

@objc private protocol DisplayReading: AnyObject {
    @objc(applySettings:) func apply(settings: AnyObject) -> Bool
    @objc(displayID) func displayID() -> UInt32
}

@objc private protocol DisplayCreating: AnyObject {
    @objc(initWithDescriptor:) init(descriptor: AnyObject)
}

@objc private protocol ModeCreating: AnyObject {
    @objc(initWithWidth:height:refreshRate:) init(width: UInt32, height: UInt32, refreshRate: Double)
}

private final class DisplayNames: @unchecked Sendable {
    private struct Entry {
        var name: String
        let isPhoneManaged: Bool
    }

    private let lock = NSLock()
    private var entries: [CGDirectDisplayID: Entry] = [:]

    func record(_ displayID: CGDirectDisplayID, name: String, isPhoneManaged: Bool) {
        lock.withLock { entries[displayID] = Entry(name: name, isPhoneManaged: isPhoneManaged) }
    }

    func record(_ displayID: CGDirectDisplayID, name: String) {
        lock.withLock {
            guard let entry = entries[displayID] else { return }
            entries[displayID] = Entry(name: name, isPhoneManaged: entry.isPhoneManaged)
        }
    }

    func forget(_ displayID: CGDirectDisplayID) {
        lock.withLock { entries[displayID] = nil }
    }

    func name(for displayID: CGDirectDisplayID) -> String? {
        lock.withLock { entries[displayID]?.name }
    }

    func isPhoneManaged(_ displayID: CGDirectDisplayID) -> Bool {
        lock.withLock { entries[displayID]?.isPhoneManaged == true }
    }
}
