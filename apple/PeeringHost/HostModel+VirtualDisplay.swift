import CoreGraphics
import Foundation
import RemoteCore

// MARK: - Virtual display

extension HostModel {
    var canShowVirtualDisplay: Bool { VirtualDisplay.isAvailable }

    /// A mode switch is invisible to the display-added/removed notification, so the source is re-requested to make the stream re-read the new size.
    func applyDeviceOrientation(isLandscape: Bool) {
        guard case .display(let id) = capturingSource,
              let target = virtualDisplayInstance(for: id),
              target.setOrientation(landscape: isLandscape)
        else { return }
        applyCaptureSource(.display(id))
    }

    /// nil for a display this host did not make.
    func virtualDisplayInstance(for displayID: CGDirectDisplayID) -> VirtualDisplay? {
        managedVirtualDisplays.first { $0.displayID == displayID }
    }
}
