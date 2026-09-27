import CoreGraphics
import Foundation
import RemoteCore

/// Holds input meant for a window on a desktop the Mac is not showing, until the Mac has gone there.
///
/// Such a window streams without being shown, so opening it does not move the Mac. Input is posted
/// at screen positions, though, and would land on whatever is showing instead. So the first
/// deliberate touch or key moves the Mac to the window's desktop, and it and everything after it
/// are held until the window is on screen, then delivered in order.
final class OffDesktopInputGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Commands waiting for the window, oldest first, or `nil` when nothing is being held.
    private var held: [RemoteCommand]?
    private let deliver: @Sendable (RemoteCommand) -> Void

    /// How long the Mac is given to bring the window on screen before the held input goes anyway.
    private static let arrivalTimeout: Duration = .milliseconds(1500)

    init(deliver: @escaping @Sendable (RemoteCommand) -> Void) {
        self.deliver = deliver
    }

    func pass(_ command: RemoteCommand, source: CaptureSource?) {
        let heldBack = lock.withLock { () -> Bool in
            guard held != nil else { return false }
            held?.append(command)
            return true
        }
        guard !heldBack else { return }

        guard case .window(let windowID)? = source,
              command.startsInteraction,
              !Self.isOnScreen(windowID)
        else {
            deliver(command)
            return
        }

        lock.withLock { held = [command] }
        Task.detached { [self] in
            await MainActor.run { _ = switchToSpace(holding: windowID) }
            let clock = ContinuousClock()
            let deadline = clock.now + Self.arrivalTimeout
            while clock.now < deadline, !Self.isOnScreen(windowID) {
                try? await Task.sleep(for: .milliseconds(40))
            }
            flush()
        }
    }

    /// Delivers what was held, including anything that arrives while it is being delivered, so
    /// nothing overtakes an older command.
    private func flush() {
        while let next = lock.withLock({ () -> RemoteCommand? in
            guard var queue = held, !queue.isEmpty else {
                held = nil
                return nil
            }
            let first = queue.removeFirst()
            held = queue
            return first
        }) {
            deliver(next)
        }
    }

    private static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else { return false }
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

private extension RemoteCommand {
    /// Input that means to act on the window. A pointer moving over it does not, so looking around
    /// a window on another desktop leaves the Mac where it is.
    var startsInteraction: Bool {
        switch self {
        case .mouseDown, .scroll, .keyDown, .textInput: return true
        default: return false
        }
    }
}
