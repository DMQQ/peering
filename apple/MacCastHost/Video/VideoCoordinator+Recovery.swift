import Foundation
import MacCastKit
import RemoteCore
import os

extension VideoCoordinator {
    /// Everything the pipeline reports lands here. A stopped stream or a dead encoder is rebuilt; the rest is for the host window.
    func captureFailed(_ error: CaptureError) {
        switch error {
        case .streamStopped(let code, _):
            // The stream is gone: a later attach must not take it for the running one. See ``ensureCapturing()``.
            lock.withLock { currentSource = nil }
            recover(from: .streamStopped(code: code), reporting: error)
        case .encodingFailed:
            recover(from: .encoderFailed, reporting: error)
        case .screenRecordingDenied, .sourceUnavailable, .catalogUnavailable, .streamFailed, .recoveryFailed:
            onFailure?(error)
        }
    }

    /// A Mac that woke from sleep or changed its displays may hold a stream that never reported its death.
    func captureEnvironmentChanged(_ cause: CaptureRecoveryBudget.Cause) {
        // With nobody watching nothing is rebuilt, but the stream may be dead behind a source that still looks current.
        if cause == .wokeFromSleep, lock.withLock({ audience.isIdle }) {
            lock.withLock { currentSource = nil }
            return
        }
        // A display change that left the stream running needs nothing; one that killed it has already cleared the source.
        if cause == .displaysChanged, lock.withLock({ currentSource }) != nil { return }
        recover(from: cause, reporting: nil)
    }

    func recover(from cause: CaptureRecoveryBudget.Cause, reporting error: CaptureError?) {
        guard lock.withLock({ !audience.isIdle }) else { return }

        switch recovery.plan(for: cause) {
        case .alreadyScheduled:
            return
        case .giveUp(let attempts):
            coordinatorLog.error("capture could not be restored after \(attempts, privacy: .public) tries")
            onFailure?(Self.giveUpError(for: error, attempts: attempts))
        case .schedule(let delay):
            coordinatorLog.notice("capture will be rebuilt in \(Int(delay), privacy: .public)s · \(String(describing: cause), privacy: .public)")
            onStatus?("Capture stopped · restarting")
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.recovery.attemptStarted()
                self.lock.withLock { self.scheduleLifecycleLocked { [weak self] in await self?.rebuildCapture() } }
            }
            recovery.hold(task)
        }
    }

    /// A missing source already has its own explanation on the phone; anything else that could not be rebuilt is reported as that.
    private static func giveUpError(for error: CaptureError?, attempts: Int) -> CaptureError {
        switch error {
        case .screenRecordingDenied?, .sourceUnavailable?: return error ?? .recoveryFailed(attempts: attempts)
        default: return .recoveryFailed(attempts: attempts)
        }
    }

    /// Takes the same path a client attach does, from a clean stop so nothing half-dead is reused.
    private func rebuildCapture() async {
        guard lock.withLock({ !audience.isIdle }) else { return }
        await pipeline.stop()
        let target = lock.withLock { chosenSource ?? currentSource ?? Self.defaultSource }
        do {
            try await startCapture(target)
            HostSessionFacts.shared.noteEncoderRestart()
            pipeline.requestKeyframe()
            if let report = recovery.attemptSucceeded() {
                HostTelemetry.error(report.code, stage: report.stage, errorCode: report.errorCode, recovered: true)
            }
        } catch {
            coordinatorLog.error("capture rebuild failed: \(String(describing: error), privacy: .public)")
            recover(from: .startFailed, reporting: error as? CaptureError)
        }
    }
}
