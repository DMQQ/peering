import ActivityKit
import Foundation

/// Takes every Live Activity down as the system terminates the app, so a killed app does not leave a running clock on the Lock Screen.
/// The system gives a few seconds and then ends the process, so this waits for the ends to be accepted rather than starting them and returning.
/// An app suspended in the background gets no such call, which is why `adoptOrphan()` still cleans up at the next launch and the Mac ends the card when the phone's connection closes.
enum LiveActivityShutdown {
    private nonisolated static let waitSeconds = 2.0

    nonisolated static func endEverything() {
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            for card in Activity<SessionActivityAttributes>.activities { await card.end(nil, dismissalPolicy: .immediate) }
            for card in Activity<TerminalActivityAttributes>.activities { await card.end(nil, dismissalPolicy: .immediate) }
            for card in Activity<AgentChatActivityAttributes>.activities { await card.end(nil, dismissalPolicy: .immediate) }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + waitSeconds)
    }
}
