import AppKit
import MacCastKit
import RemoteCore

extension HostModel {
    /// Sleep and display changes kill a stream, sometimes without a stop error. Each starts a controlled rebuild, which the coordinator skips when nobody is watching.
    func startCaptureEnvironmentWatch() {
        guard captureEnvironmentObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.captureEnvironmentChanged(.wokeFromSleep) }
        }
        let screensWake = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.captureEnvironmentChanged(.wokeFromSleep) }
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.captureEnvironmentChanged(.displaysChanged) }
        }
        captureEnvironmentObservers = [(workspace, wake), (workspace, screensWake), (NotificationCenter.default, screens)]
    }

    func stopCaptureEnvironmentWatch() {
        for (center, observer) in captureEnvironmentObservers { center.removeObserver(observer) }
        captureEnvironmentObservers = []
    }

    /// Takes back the notice that said the picture could not be restored.
    func captureWasRestored() {
        guard announcedCaptureProblem != nil else { return }
        announcedCaptureProblem = nil
        server?.broadcastNotice(NoticePayload(message: nil))
    }
}
