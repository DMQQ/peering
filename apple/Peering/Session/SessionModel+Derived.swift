import PeeringKit
import RemoteCore
import UIKit

extension SessionModel {
    var activeSession: MacSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// Not `sessions`: an ended session is kept until the next arrives so its failure can be read, and it is not a tab.
    var openSessions: [MacSession] { sessions.filter(\.isLive) }

    var hasOpenSession: Bool { !openSessions.isEmpty }

    /// The phase carries it, and the picker needs it: otherwise an instantly failed connection looks like a button that did nothing.
    var failureCause: ClientSession.FailureCause? { activeSession?.failureCause }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var isWaitingForHost: Bool { pendingHostID != nil }

    /// The one thing that can turn a feature off outright: it promises the Mac's device ID and connection times never reach a server, keepable only if this gates every dial (`connectToTrusted`, `reconnectToLastHost`, `resumeIfNeeded`, `pairWithRemoteMac`).
    /// Read through `object(forKey:)` so unset is distinguishable from off: the default is on.
    var allowsRelay: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.allowRelay) as? Bool ?? true
    }

    var thisDeviceDescription: String { "\(device.name) · \(device.id)" }

    var allMacros: [Macro] { Macro.defaults + customMacros }

    /// The size identifies the stream, as the order a frame and its config reach the main actor cannot be relied on.
    func isReadyToPlace(of size: CGSize) -> Bool {
        let snapshot = renderer.currentSnapshot
        return snapshot.configGeneration > 0
            && snapshot.readyGeneration == snapshot.configGeneration
            && snapshot.pixelWidth == Int(size.width)
            && snapshot.pixelHeight == Int(size.height)
    }

    /// Closing alone is not enough: a failed attempt during a resume is swallowed, so the phase can be left on a connecting state with nothing behind it.
    func dismissSpentAllowance() {
        spentAllowance = nil
        if phase.holdsSession, phase != .ready {
            disconnect()
        }
    }

    static var defaultDeviceName: String {
        // UIDevice.current.name needs Apple approval for the custom name entitlement on iOS 16+, so
        // fall back to a recognisable-enough label until the user sets one in Settings.
        let name = UIDevice.current.name
        if name.lowercased() == "iphone" || name.lowercased() == "ipad" {
            return UIDevice.current.localizedModel + " (" + UIDevice.current.systemVersion + ")"
        }
        return name
    }
}
