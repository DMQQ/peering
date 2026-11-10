import Foundation
import RemoteCore
import os

extension VideoCoordinator {
    /// Rebuilds the capture of the current source twice after a desktop switch: once while the slide is still playing and once after it. The stream stops delivering mid-slide and a settled screen asks for nothing more, so the phone froze on half a transition; a fresh stream starts with a frame of whatever is on screen then. A redraw request on the old stream was no use, it waited out the transition itself.
    func rebuildCaptureAfterSpaceSwitch() {
        Task { [weak self] in
            var elapsed = Duration.zero
            for moment in [Duration.milliseconds(300), .milliseconds(1_000)] {
                try? await Task.sleep(for: moment - elapsed)
                elapsed = moment
                guard let self else { return }
                await self.rebuildCapture()
            }
        }
    }

    private func rebuildCapture() async {
        let operation = lock.withLock { () -> Task<Void, Never>? in
            guard let source = currentSource, !source.isMosaic, !audience.isIdle else { return nil }
            let previous = lifecycleTail
            let operation = Task { [weak self] in
                if let previous { await previous.value }
                guard let self, self.lock.withLock({ self.currentSource }) == source, self.lock.withLock({ !self.audience.isIdle }) else { return }
                do {
                    try await self.startCapture(source)
                } catch {
                    coordinatorLog.error("the capture could not be rebuilt after a desktop switch: \(String(describing: error), privacy: .public)")
                }
            }
            lifecycleTail = Task { _ = await operation.value }
            return operation
        }
        await operation?.value
    }
}
