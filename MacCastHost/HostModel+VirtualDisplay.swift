import CoreGraphics
import Foundation
import RemoteCore

// MARK: - Virtual display

extension HostModel {
    /// Whether this Mac's system software has the API at all.
    ///
    /// Read before a request is attempted, so a Mac that never had the API refuses with a sentence
    /// rather than failing inside the window server. See
    /// ``HostModel/addVirtualDisplay(name:width:height:startLandscape:)``.
    var canShowVirtualDisplay: Bool { VirtualDisplay.isAvailable }

    /// Rotates a virtual display to match the phone, and rebuilds the stream at the new size when
    /// that display is the one currently on screen.
    ///
    /// ``VirtualDisplay/setOrientation(landscape:)`` only ever switches a `CGDisplayMode`, which
    /// is not something ``VideoCoordinator`` watches for on its own: the display-added/removed
    /// notification its catalogue listens for does not distinguish a mode switch from nothing
    /// happening at all. So the same source is asked for again, through the exact path a client's
    /// own tap on a Sources tile takes, which is what makes the stream re-read the display's now
    /// different pixel size rather than go on encoding the shape it started with.
    func applyDeviceOrientation(isLandscape: Bool) {
        guard case .display(let id) = capturingSource,
              let target = virtualDisplayInstance(for: id),
              target.setOrientation(landscape: isLandscape)
        else { return }
        applyCaptureSource(.display(id))
    }

    /// The ``VirtualDisplay`` this host made for `displayID`, or `nil` for a display it did not
    /// make.
    ///
    /// **One store, because there is one way for a display like this to exist**: a phone asked for
    /// it. There used to be a second one for a display the Mac's own switch made, which was free on
    /// every plan and was the Mac's own setting; creation is the phone's alone now, and the phone
    /// pays for it. See ``managedVirtualDisplays``.
    func virtualDisplayInstance(for displayID: CGDirectDisplayID) -> VirtualDisplay? {
        managedVirtualDisplays.first { $0.displayID == displayID }
    }
}
