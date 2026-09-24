import CoreGraphics
import Foundation
import os

private let virtualDisplayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A second monitor that exists only in software, shaped like the phone.
///
/// The problem it solves is a shape, not a size: a 27-inch desktop letterboxed into a phone is a
/// picture of a display the phone is not, and half the phone's screen is spent on bars. Nothing in
/// the protocol knows the difference: a virtual display is a ``CaptureSource/display(_:)`` with a
/// display ID, and ``CaptureSourceResolver`` offers it as an ordinary display.
///
/// Private API, deliberately, and only here. `CGVirtualDisplay` is a CoreGraphics class with no
/// header, and the host is distributed outside the App Store as a notarised DMG, which
/// notarisation does not reject. It is host-only in the strong sense: nothing in `MacCast`,
/// `MacCastKit` or `RemoteCore` may reach for it, because the phone would be rejected for it.
///
/// Three things here are not what the widely copied header says. The classes were read back with
/// `class_copyMethodList` on macOS 27 rather than trusted from memory:
///
/// - `setTerminalID:` does not exist. Sending it raises an `NSException`, which cannot be caught
///   in Swift, so a wrong selector here is a crash and not an error. The field is
///   `setSerialNumber:`.
/// - `hiDPI` in the settings does not make a display denser: a descriptor of 1720×3728 with a
///   mode of 860×1864 and `hiDPI` set came back as 1720×3728 points at a 1× backing scale. The
///   mode is the size, so this file asks for what it wants as a mode and gets exactly that.
/// - There is no `alloc` to pair with: `initWithDescriptor:` both allocates and initialises, and
///   the object it returns is the entire lifetime of the display.
///
/// The display lives exactly as long as this object. Releasing the last reference takes it away,
/// and so does killing the process; there is no unregister call to forget. That is the trap: any
/// strong reference kept anywhere else (a proxy, a captured closure, a lazy property) is a monitor
/// on the user's Mac that they cannot get rid of.
final class VirtualDisplay {
    enum Failure: LocalizedError {
        /// The private classes are not on this Mac.
        case unavailable
        /// A display was made and the window server would not take it.
        case refused(CGSize)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This Mac's system software does not have the virtual display API."
            case .refused(let size):
                return "The system refused a \(Int(size.width))×\(Int(size.height)) virtual display."
            }
        }
    }

/// The shape built when the user turns the switch on: the largest recent iPhone's screen, in its
/// own pixels.
///
/// Points and pixels are the same number here, and that is the decision. The stream is configured
/// from what a display reports, which for a display is ``CaptureResolution/pixelSize(for:)``
/// reading `CGDisplayPixelsWide`; on a Retina panel that answers with the point size, so a display
/// built with a 2× backing would be streamed at half its pixels. At 1× the picture arrives at
/// 1290×2796, which is the phone's screen pixel for pixel, and the point space is wide enough that
/// a window dragged over from a 1512-point Mac keeps the size it already had.
///
/// A default rather than something the phone asked for, and it has to be: the switch is on the Mac
/// and is thrown whether or not a phone is connected. 19.5:9 is the shape every iPhone since the X
/// shares. Portrait, in the sense every iPhone box photo uses it — ``init(size:name:startLandscape:)``
/// defaults to showing it the other way round, which is the shape someone actually working at this
/// display wants.
    static let phoneShaped = CGSize(width: 1290, height: 2796)

/// Whether the private classes are there at all.
///
/// Asked before the switch is offered rather than assumed when it is thrown, so a macOS that
/// removes the class leaves the user with a switch that says so rather than a failure on every
/// launch. It is a lookup and not a probe.
    static var isAvailable: Bool {
        descriptorClass != nil && displayClass != nil && settingsClass != nil && modeClass != nil
    }

    /// The display's ID, which is all any other type in the app should hold.
    let displayID: CGDirectDisplayID

/// The two shapes this display was built with, portrait first regardless of which way it starts.
/// ``setOrientation(landscape:)`` switches between exactly these two pixel sizes and nothing
/// else, so a size this display was never given is not a mode it can be asked to become.
    private let portraitPixelSize: CGSize
    private let landscapePixelSize: CGSize

/// The orientation last asked for, so a repeated report of the same orientation is not a second
/// mode switch. Set from whichever mode the display actually started in.
    private(set) var isLandscape: Bool

/// Whether this process's own display list corroborated the display before the deadline.
///
/// Advisory, and never a reason to throw. This Mac's `CGGetActiveDisplayList` can report only the
/// built-in panel for the whole wait while the window server has already created and enabled the
/// display. The display is real either way, so what a list that disagrees is worth is the caller's
/// call, not this type's.
    let appearedInList: Bool

/// The display, and the whole reason it exists.
///
/// Held as `AnyObject` because the class is not in any header the compiler can see. Everything
/// else about the display is asked of the window server by ID, so nothing here is reached again.
    private var display: AnyObject?

/// The names this process has given the displays it made, by display ID, for the catalogue to
/// offer them under.
///
/// `NSScreen` cannot be relied on to adopt a virtual display: a process that reads
/// `NSScreen.screens` before the display exists never sees it appear afterwards, while one that
/// reads the list for the first time after it exists does. ``CaptureSourceResolver`` names every
/// display from `NSScreen`, so without this the one display the user made on purpose would be
/// offered to their phone as "Display 13".
    private static let names = DisplayNames()

    /// A name for a display this process made, or `nil` for every other display on the Mac.
    static func name(for displayID: CGDirectDisplayID) -> String? {
        names.name(for: displayID)
    }

/// Makes a display of the given pixel size and shows it to the window server.
///
/// `size` is always read as portrait, whichever way `startLandscape` shows it first: the two are
/// what ``setOrientation(landscape:)`` will ever switch this display between, registered as two
/// modes on the one display rather than as anything that could be mistaken for a second one.
///
/// Throws only when the window server would not take the display at all. What this process can see
/// of it afterwards is ``appearedInList``, which is reported rather than judged here.
///
/// A failure at any point releases what was made, because the local reference going out of scope
/// is the same thing as the display never having existed.
    init(
        size: CGSize = VirtualDisplay.phoneShaped,
        name: String = "Peering Phone Display",
        startLandscape: Bool = true
    ) throws {
        guard let descriptorClass = Self.descriptorClass,
              let displayClass = Self.displayClass,
              let settingsClass = Self.settingsClass,
              let modeClass = Self.modeClass
        else { throw Failure.unavailable }

// Built here from the classes the guard just unwrapped, rather than as lazily initialised
// statics: a static holding the bitcast of a class that turned out not to be there would be a nil
// passed to `initWithDescriptor:`, which is a crash a long way from the reason.
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
// The ceiling either mode below may ever be asked for, not the size it starts at: the longer side
// of the phone's shape either way round, so a rotation is a mode switch and never a resize past
// what the panel was described with.
        let longSide = max(portraitWidth, portraitHeight)
        descriptor.put(maxPixelsWide: longSide)
        descriptor.put(maxPixelsHigh: longSide)
// The panel's physical size, which is cosmetic and, measured, ignored: this panel comes back from
// `CGDisplayScreenSize` as the same size at 72 dpi. The field is filled in anyway because a
// descriptor that leaves out a field the private API documents is the kind of omission that shows
// up later as a display that does not appear at all.
        descriptor.put(sizeInMillimeters: Self.millimetres(for: portrait))
// Identity, so this panel is recognisably the same panel across launches rather than a new device
// every time. The serial is fixed for the same reason, because there is only ever one of these.
        descriptor.put(serialNumber: 1)
        descriptor.put(productID: 0x5045) // "PE"
        descriptor.put(vendorID: 0x646D)  // "dm", this developer's prefix

        let displayObject = displayFactory.init(descriptor: descriptorObject)

        let settingsObject = settingsClass.init()
        let settings = unsafeBitCast(settingsObject, to: SettingsWriting.self)
// The mode is the whole of the size (see the type's note on `hiDPI`), so both modes are asked for
// at exactly the sizes the display was described with. 60 Hz because a phone cannot show more.
// The one the display should start in comes first: observed to be what the window server actually
// picks as current, and forced again below regardless, so this is belt over braces.
        let portraitMode = modeFactory.init(width: portraitWidth, height: portraitHeight, refreshRate: 60)
        let landscapeMode = modeFactory.init(width: portraitHeight, height: portraitWidth, refreshRate: 60)
        settings.put(modes: startLandscape ? [landscapeMode, portraitMode] : [portraitMode, landscapeMode])

        let proxy = unsafeBitCast(displayObject, to: DisplayReading.self)
        let applied = proxy.apply(settings: settingsObject)
// The ID in a local as well as the property, because the log line below is built in a closure and
// a property read inside one has to be written `self.` in an initialiser.
        let id = proxy.displayID()
        displayID = id
        guard applied, id != 0 else { throw Failure.refused(size) }

// The window server takes the display asynchronously, so "is it there yet" is a poll and not a
// property of the call that made it. Three seconds is far longer than the low hundreds of
// milliseconds it takes, and the cost of waiting is a switch that moves a moment after it is
// clicked.
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
        Self.names.record(id, name: name)
// Forced rather than trusted to the mode order above: this is the one call that is actually
// documented to select the current mode, and a rotation later has to trust the same call, so the
// starting shape is made by the exact route that will be asked to change it.
        if appearedInList {
            _ = Self.applyMode(id, size: startLandscape ? landscape : portrait)
        }
        let origin = CGDisplayBounds(id).origin
        let active = startLandscape ? landscape : portrait
        virtualDisplayLog.notice("""
            virtual display \(id, privacy: .public) on screen at \
            \(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public) · \
            \(Int(active.width), privacy: .public)×\(Int(active.height), privacy: .public) pixels
            """)
    }

/// Takes the display away, and reports whether the window server let go of it.
///
/// Dropping the reference is the whole of the teardown. The poll is there because the removal is
/// asynchronous: the caller is a switch that has just been turned off, and it has to know whether
/// the monitor it created is really gone before it says so. A `false` here is worth a log line
/// rather than a retry, because there is no second reference to drop.
    @discardableResult
    func remove() -> Bool {
// Asked without binding: a `guard let display` here would hold a second strong reference for the
// length of this function, so the release below would not be the release and the poll would report
// a display that is on its way out as one that will not go.
        guard display != nil else { return true }
        Self.names.forget(displayID)
        self.display = nil

        let gone = Self.waitForDeparture(of: displayID)
        if gone {
            virtualDisplayLog.notice("virtual display \(self.displayID, privacy: .public) removed")
        } else {
            virtualDisplayLog.error("""
                virtual display \(self.displayID, privacy: .public) was released and is still on \
                screen; the window server did not let go of it
                """)
        }
        return gone
    }

/// Rotates the display's shape to match the phone, live, without tearing anything down.
///
/// A second registered mode is not a second display: modes are what a real monitor offers under
/// System Settings' resolution list, and ``applyMode(_:size:)`` — public `CGDisplaySetDisplayMode`,
/// unlike everything above it in this file — is the ordinary way an app switches one. Recreating
/// the display for a rotation would trip the identity trap this type's own header describes: this
/// Mac refuses a second display sharing a vendor, product and serial, and there is no reason to
/// risk that when nothing about the display's identity needs to change for its shape to.
///
/// Returns whether the window server accepted the switch. A repeat of the orientation already
/// showing is reported `true` without asking the window server anything, which keeps a client that
/// reports its orientation on every layout pass from being a client that reconfigures a display on
/// every layout pass.
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

/// Switches `displayID`'s current `CGDisplayMode` to whichever of its registered modes is exactly
/// `size` in pixels.
///
/// Public API throughout, on purpose: this is the one step in rotating a virtual display that has
/// a documented entry point, so it is the one written against the SDK rather than a class read
/// back at runtime.
    private static func applyMode(_ displayID: CGDirectDisplayID, size: CGSize) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let target = modes.first(where: {
                  $0.pixelWidth == Int(size.width) && $0.pixelHeight == Int(size.height)
              })
        else { return false }
        return CGDisplaySetDisplayMode(displayID, target, nil) == CGError.success
    }

    // MARK: - The window server's view

/// Every display the window server has, in its own order.
///
/// `CGGetActiveDisplayList` rather than `NSScreen.screens`, for the reason on ``names``: a virtual
/// display may or may not be in AppKit's list depending on when that list was last built.
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

/// Polls a condition to a deadline, with a short wait between reads.
///
/// The main thread's run loop is turned rather than slept: the window server announces a display
/// change to the main run loop and waits for an answer before it lets go, and a thread asleep in
/// `Thread.sleep` cannot give one. Off the main thread there is no run loop owed to anyone, so
/// that path still sleeps.
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

/// A phone-shaped panel's physical size, from the pixel size at the phone's pixel density.
///
/// 460 ppi, which is what the phone this is shaped after has. Only the descriptor's bookkeeping
/// uses it.
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

/// The setters `CGVirtualDisplayDescriptor` has, and the only ones this app uses.
///
/// Declared to match the class as it is on macOS 27, not as it is in the header that circulates.
/// `unsigned int` throughout rather than `Int`, because that is the field width the class was
/// compiled with.
///
/// Every protocol below is reached by `unsafeBitCast` rather than by a cast: a cast to a protocol
/// runs a conformance check at runtime, and a private class does not conform to a protocol it has
/// never heard of, so `as?` would answer `nil` for exactly the objects this file exists to use.
/// Nothing checks the signatures either, so a selector renamed upstream is a crash rather than a
/// compile error.
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

/// `CGVirtualDisplaySettings`, which is the mode list and nothing else this app sets.
@objc private protocol SettingsWriting: AnyObject {
    @objc(setModes:) func put(modes: NSArray)
}

/// `CGVirtualDisplay`, as the display the user sees.
@objc private protocol DisplayReading: AnyObject {
    @objc(applySettings:) func apply(settings: AnyObject) -> Bool
    @objc(displayID) func displayID() -> UInt32
}

/// The class methods that make a display and a mode.
@objc private protocol DisplayCreating: AnyObject {
    @objc(initWithDescriptor:) init(descriptor: AnyObject)
}

@objc private protocol ModeCreating: AnyObject {
    @objc(initWithWidth:height:refreshRate:) init(width: UInt32, height: UInt32, refreshRate: Double)
}

/// The names this process gave the displays it made, for the catalogue to offer them under.
///
/// Lock-guarded rather than main-actor state, because the catalogue is built off the main actor
/// and asks for a name from wherever that lands.
private final class DisplayNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [CGDirectDisplayID: String] = [:]

    func record(_ displayID: CGDirectDisplayID, name: String) {
        lock.withLock { names[displayID] = name }
    }

    func forget(_ displayID: CGDirectDisplayID) {
        lock.withLock { names[displayID] = nil }
    }

    func name(for displayID: CGDirectDisplayID) -> String? {
        lock.withLock { names[displayID] }
    }
}
