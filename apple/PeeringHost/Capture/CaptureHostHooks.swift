import Foundation
import os

/// What capture code tells the app around it. The host installs both at launch; a probe that compiles this folder leaves them empty.
enum CaptureHostHooks {
    private struct Handlers {
        var failure: (@Sendable (Error) -> Void)?
        var encoderRestarted: (@Sendable () -> Void)?
    }

    private static let handlers = OSAllocatedUnfairLock(initialState: Handlers())

    static func install(
        failure: @escaping @Sendable (Error) -> Void,
        encoderRestarted: @escaping @Sendable () -> Void
    ) {
        handlers.withLock { $0 = Handlers(failure: failure, encoderRestarted: encoderRestarted) }
    }

    static func reportFailure(_ error: Error) {
        let handler = handlers.withLock { $0.failure }
        handler?(error)
    }

    static func noteEncoderRestart() {
        let handler = handlers.withLock { $0.encoderRestarted }
        handler?()
    }
}
