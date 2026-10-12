import AppKit
import Foundation
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Commands the host answers itself instead of injecting as input.
extension HostModel {
    /// Hands a command to the part of the host that answers it. False means it is plain input for the injector.
    nonisolated static func dispatch(_ command: RemoteCommand, to model: HostModel?, coordinator: VideoCoordinator) -> Bool {
        dispatchToCoordinator(command, coordinator) || dispatchToModel(command, model)
    }

    /// Straight through, off the main actor: these concern the capture's own queues.
    private nonisolated static func dispatchToCoordinator(_ command: RemoteCommand, _ coordinator: VideoCoordinator) -> Bool {
        switch command {
        case .setStreamQuality(let fps, let bitrateKbps):
            coordinator.setStreamQuality(fps: fps, bitrateKbps: bitrateKbps)
        case .refreshSpacePreviews:
            coordinator.refreshSpacePreviews()
        case .refreshSourceThumbnails:
            coordinator.refreshSourceThumbnails()
        case .watchSourceThumbnails(let watching):
            coordinator.watchSourceThumbnails(watching)
        default:
            return false
        }
        return true
    }

    private nonisolated static func dispatchToModel(_ command: RemoteCommand, _ model: HostModel?) -> Bool {
        switch command {
        case .setCaptureSource(let source):
            Task { @MainActor [weak model] in
                model?.pendingCaptureSource = source
                model?.applyCaptureSource(source)
            }
        case .launchApplication(let bundleIdentifier):
            Task { @MainActor [weak model] in model?.launchApplication(bundleIdentifier: bundleIdentifier) }
        case .reportDeviceOrientation(let isLandscape):
            Task { @MainActor [weak model] in model?.applyDeviceOrientation(isLandscape: isLandscape) }
        case .setPrivacyMode(let enabled):
            Task { @MainActor [weak model] in model?.setPrivacyMode(enabled) }
        case .lockScreen:
            Task { @MainActor in Self.postLockScreenShortcut() }
        default:
            return dispatchWindowManagement(command, model)
        }
        return true
    }

    private nonisolated static func dispatchWindowManagement(_ command: RemoteCommand, _ model: HostModel?) -> Bool {
        switch command {
        case .addVirtualDisplay(let name, let width, let height, let startLandscape):
            Task { @MainActor [weak model] in
                model?.addVirtualDisplay(name: name, width: width, height: height, startLandscape: startLandscape)
            }
        case .removeVirtualDisplay(let displayID):
            Task { @MainActor [weak model] in await model?.removeVirtualDisplay(displayID: displayID) }
        case .renameVirtualDisplay(let displayID, let name):
            Task { @MainActor [weak model] in model?.renameVirtualDisplay(displayID: displayID, name: name) }
        case .performWindowAction(let windowID, let action):
            Task { @MainActor [weak model] in model?.performWindowAction(action, windowID: windowID) }
        case .openNewWindow(let bundleIdentifier):
            Task { @MainActor [weak model] in model?.openNewWindow(bundleIdentifier: bundleIdentifier) }
        case .switchToSpace(let display, let index):
            Task { @MainActor [weak model] in
                guard let model else { return }
                // switchToSpace returns whether the window server accepted the move; whether the picture followed arrives later, see report(spaceSwitchRoute:index:display:).
                _ = switchToSpace(display: display, index: index) { route in
                    Task { @MainActor in
                        model.report(spaceSwitchRoute: route, index: index, display: display)
                    }
                }
            }
        case .switchSpace(let direction):
            Task { @MainActor in _ = switchSpaceRelative(direction: direction) }
        default:
            return false
        }
        return true
    }

    @MainActor
    private static func postLockScreenShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Keycode 12 is `Q`. 0x19 is `L`, which is silently not the lock shortcut.
        let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false)
        down?.flags = [.maskCommand, .maskControl]
        up?.flags = [.maskCommand, .maskControl]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        hostLog.notice("lock screen shortcut posted")
    }
}
