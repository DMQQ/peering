import CoreGraphics
import Foundation
import os

private let virtualDisplayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A second monitor that exists only in software, shaped like the phone.
///
/// The problem it solves is a shape, not a size: a 27-inch desktop letterboxed into a phone is a
/// picture of a display the phone is not, and half the phone's screen is spent on bars. A display
/// of the phone's own shape lets the user put windows where they will actually be seen, arrange
/// them into whatever mosaic they want, and have the app stream that display like any other
/// screen. Nothing in the protocol knows the difference: a virtual display is a
/// ``CaptureSource/display(_:)`` with a display ID, and ``CaptureSourceResolver`` offers it as an
/// ordinary display without a line of new code. The one line this feature did add there is the
/// name it is offered under, and the reason is on ``names`` below.
///
/// **Private API, deliberately, and only here.** `CGVirtualDisplay` is a CoreGraphics class with
/// no header. The host is distributed outside the App Store as a notarised DMG, and notarisation
/// does not reject a private class; the App Store is not a target of this app for reasons that
/// predate this file. It is host-only in the strong sense: nothing in `MacCast`, `MacCastKit` or
/// `RemoteCore` may reach for it, because the phone would be rejected for it and has no use for it
/// anyway: the phone is what the display is shaped *for*.
///
/// **Three things here are not what the widely copied header says**, and each one cost a crash or
/// a silent no-op to find on macOS 27. The classes were read back with `class_copyMethodList`
/// rather than trusted from memory:
///
/// - `setTerminalID:` does not exist. Sending it raises an `NSException`, which cannot be caught
///   in Swift, so a wrong selector here is a crash and not an error. The field is
///   `setSerialNumber:` now.
/// - `hiDPI` in the settings does not do what its name suggests to a display the window server
///   has never seen: a descriptor of 1720×3728 with a mode of 860×1864 and `hiDPI` set came back
///   as a 1720×3728-point display at a 1× backing scale, which is neither the mode that was asked
///   for nor a Retina display. Whatever it is for, it is not how a display is made twice as dense
///   here, so this file asks for the size it wants as a mode and gets exactly that.
/// - There is no `alloc` to pair with: `initWithDescriptor:` both allocates and initialises, and
///   the object it returns is the entire lifetime of the display.
///
/// **The display lives exactly as long as this object.** Releasing the last reference takes it
/// away, measured in the low hundreds of milliseconds, and so does killing the process. That is
/// the whole teardown path, which is the good news (there is no unregister call to forget) and
/// the trap: any strong reference kept anywhere else (a proxy, a captured closure, a lazy
/// property) is a monitor on the user's Mac that they cannot get rid of. Hence the single stored
/// property, and a display ID handed out for everything else to hold instead.
final class VirtualDisplay {
    enum Failure: LocalizedError {
        /// The private classes are not on this Mac.
        case unavailable
        /// A display was made and the window server would not take it.
        case refused(CGSize)
        /// It was taken, and never appeared in the display list.
        case neverAppeared(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This Mac's system software does not have the virtual display API."
            case .refused(let size):
                return "The system refused a \(Int(size.width))×\(Int(size.height)) virtual display."
            case .neverAppeared(let id):
                return "The virtual display was created (id \(id)) but never appeared on screen."
            }
        }
    }

    /// The shape built when the user turns the switch on: the largest recent iPhone's screen,
    /// in its own pixels.
    ///
    /// **Points and pixels are the same number here, and that is the decision.** The stream is
    /// configured from what a display reports, and for a display that is
    /// ``CaptureResolution/pixelSize(for:)``, which reads `CGDisplayPixelsWide`. On a Retina panel
    /// that answers with the *point* size, so a display built with a 2× backing would be streamed
    /// at half its pixels and the phone would be looking at half its own resolution. At 1× the
    /// picture arrives at 1290×2796, which is the phone's screen pixel for pixel, and the point
    /// space is wide enough that a window dragged over from a 1512-point Mac keeps the size it
    /// already had instead of having to be shrunk to fit.
    ///
    /// The size is a default rather than something the phone asked for, and it has to be: the
    /// switch is on the Mac, and it is thrown whether or not a phone is connected. 19.5:9 is the
    /// shape every iPhone since the X shares, so a smaller phone shows the same picture with
    /// nothing letterboxed, and a bigger one is not yet a thing that exists.
    static let phoneShaped = CGSize(width: 1290, height: 2796)

    /// Whether the private classes are there at all.
    ///
    /// Asked before the switch is offered rather than assumed when it is thrown: a macOS that
    /// removes the class has to leave the user with a switch that says so, not with a failure on
    /// every launch. It is a lookup and not a probe: constructing a display to find out is what
    /// the switch is for.
    static var isAvailable: Bool {
        descriptorClass != nil && displayClass != nil && settingsClass != nil && modeClass != nil
    }

    /// The display's ID, which is all any other type in the app should hold.
    let displayID: CGDirectDisplayID

    /// The display, and the whole reason it exists.
    ///
    /// Held as `AnyObject` because there is no type for it to be: the class is not in any header
    /// the compiler can see. Everything else about the display (its name, its geometry) is asked
    /// of the window server by ID, so nothing here needs to be reached again after this.
    private var display: AnyObject?

    /// The names this process has given the displays it made, by display ID, for the catalogue to
    /// offer them under.
    ///
    /// **`NSScreen` cannot be relied on to adopt a virtual display**, measured on macOS 27 in both
    /// directions: a process that reads `NSScreen.screens` *before* the display exists never sees
    /// it appear afterwards, `NSApplication` running its loop or not, while a process that reads
    /// the list for the first time after it exists does. The window server has it either way
    /// (`CGGetActiveDisplayList` lists it within a second), and ``CaptureSourceResolver`` names
    /// every display from `NSScreen`, so without this the one display the user made on purpose
    /// would be offered to their phone as "Display 13".
    private static let names = DisplayNames()

    /// A name for a display this process made, or `nil` for every other display on the Mac.
    static func name(for displayID: CGDirectDisplayID) -> String? {
        names.name(for: displayID)
    }

    /// Makes a display of the given pixel size and shows it to the window server.
    ///
    /// Throws rather than returning an optional, and only after checking that the display is
    /// really there: "the call returned true" is not the same answer as "the user has a monitor",
    /// and the caller is a switch that has to tell the truth either way.
    ///
    /// A failure at any point releases what was made, because the local reference going out of
    /// scope is the same thing as the display never having existed.
    init(size: CGSize = VirtualDisplay.phoneShaped, name: String = "Peering Phone Display") throws {
        guard let descriptorClass = Self.descriptorClass,
              let displayClass = Self.displayClass,
              let settingsClass = Self.settingsClass,
              let modeClass = Self.modeClass
        else { throw Failure.unavailable }

        // Built here from the classes the guard just unwrapped, rather than as lazily initialised
        // statics: a static holding the bitcast of a class that turned out not to be there would
        // be a nil passed to `initWithDescriptor:`, which is a crash a long way from the reason.
        let displayFactory = unsafeBitCast(displayClass, to: DisplayCreating.Type.self)
        let modeFactory = unsafeBitCast(modeClass, to: ModeCreating.Type.self)

        let width = UInt32(max(2, size.width.rounded(.down)))
        let height = UInt32(max(2, size.height.rounded(.down)))

        let descriptorObject = descriptorClass.init()
        let descriptor = unsafeBitCast(descriptorObject, to: DescriptorWriting.self)
        descriptor.put(queue: .main)
        descriptor.put(name: name as NSString)
        // The ceiling the display may ever be asked for, not the size it starts at. Set to the
        // mode below so nothing can resize this panel behind the app's back: the stream's size
        // and the phone's shape are both this number.
        descriptor.put(maxPixelsWide: width)
        descriptor.put(maxPixelsHigh: height)
        // The panel's physical size, which is cosmetic and, measured, ignored: a 1290×2796
        // display asked for at 460 ppi comes back from `CGDisplayScreenSize` as 0×0 while it is
        // still settling and then as 455×986 mm, which is the same panel at 72 dpi. Nothing in
        // the app reads it for anything (see ``phoneShaped`` for what actually decides the size),
        // and the field is filled in anyway because a descriptor that leaves out a field the
        // private API documents is the kind of omission that shows up later as a display that
        // does not appear at all.
        descriptor.put(sizeInMillimeters: Self.millimetres(for: size))
        // Identity, so this panel is recognisably the same panel across launches rather than a
        // new device every time. The vendor and product IDs are this app's own; the serial is
        // fixed for the same reason, because there is only ever one of these displays.
        descriptor.put(serialNumber: 1)
        descriptor.put(productID: 0x5045) // "PE"
        descriptor.put(vendorID: 0x646D)  // "dm", this developer's prefix

        let displayObject = displayFactory.init(descriptor: descriptorObject)

        let settingsObject = settingsClass.init()
        let settings = unsafeBitCast(settingsObject, to: SettingsWriting.self)
        // The mode is the whole of the size (see the type's note on `hiDPI`), so one mode is
        // asked for and it is exactly the size the display was described with. 60 Hz because a
        // stream is a stream: a phone cannot show more.
        let mode = modeFactory.init(width: width, height: height, refreshRate: 60)
        settings.put(modes: [mode])

        let proxy = unsafeBitCast(displayObject, to: DisplayReading.self)
        let applied = proxy.apply(settings: settingsObject)
        // The ID in a local as well as the property, because the log line below is built in a
        // closure and a property read inside one has to be written `self.` in an initialiser.
        let id = proxy.displayID()
        displayID = id
        guard applied, id != 0 else { throw Failure.refused(size) }

        // The window server takes the display asynchronously, so "is it there yet" is a poll and
        // not a property of the call that made it. Three seconds is far longer than the low
        // hundreds of milliseconds it takes, and the cost of waiting is a switch that moves a
        // moment after it is clicked.
        guard Self.waitForAppearance(of: displayID) else { throw Failure.neverAppeared(displayID) }

        self.display = displayObject
        Self.names.record(id, name: name)
        let origin = CGDisplayBounds(id).origin
        virtualDisplayLog.notice("""
            virtual display \(id, privacy: .public) on screen at \
            \(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public) · \
            \(Int(width), privacy: .public)×\(Int(height), privacy: .public) pixels
            """)
    }

    /// Takes the display away, and reports whether the window server let go of it.
    ///
    /// Dropping the reference is the whole of the teardown, and the poll is there because the
    /// removal is asynchronous: the caller is a switch that has just been turned off, and it has
    /// to know whether the monitor it created is really gone before it says so. A `false` here is
    /// worth a log line rather than a retry, because there is no second reference to drop.
    @discardableResult
    func remove() -> Bool {
        // Asked without binding, deliberately: a `guard let display` here would hold a second
        // strong reference for the length of this function, so the release below would not be the
        // release and the poll at the end of it would report a display that is on its way out as
        // one that will not go. The reference count has to reach zero before the waiting starts.
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

    // MARK: - The window server's view

    /// Every display the window server has, in its own order.
    ///
    /// `CGGetActiveDisplayList` rather than `NSScreen.screens`, for the reason on ``names``: a
    /// virtual display may or may not be in AppKit's list depending on when that list was last
    /// built, so anything that asks AppKit whether this worked can be told no for a display that
    /// is on screen and streaming.
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

    /// Polls a condition to a deadline, with a short sleep between reads.
    ///
    /// The sleep is on the calling thread rather than a run loop turn, because both callers are
    /// on their way to a decision the user is waiting for and neither has anything else to do;
    /// the display arriving does not need this process to service a queue.
    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// A phone-shaped panel's physical size, from the pixel size at the phone's pixel density.
    ///
    /// 460 ppi, which is what the phone this is shaped after has. Only the descriptor's
    /// bookkeeping uses it.
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
/// Declared to match the class as it is on macOS 27, which is not as it is in the header that
/// circulates. `unsigned int` throughout rather than `Int`, because that is the field width the
/// class was compiled with and a Swift `Int` would put the value in the right register with the
/// wrong upper bits.
///
/// Every protocol below is reached by `unsafeBitCast` rather than by a cast, and that is the one
/// thing to keep in mind when changing any of them: a cast to a protocol runs a conformance check
/// at runtime, and a private class does not conform to a protocol it has never heard of, so `as?`
/// would answer `nil` for exactly the objects this file exists to use. Nothing checks the
/// *signatures* either, so a selector that has been renamed upstream is a crash rather than a
/// compile error, which is why each one was read off the class rather than written from memory.
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
/// and asks for a name from wherever that lands. Two displays at once is not a case this app has
/// (the switch is one switch), but a dictionary that only ever held one entry would be a
/// coincidence rather than a design.
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
