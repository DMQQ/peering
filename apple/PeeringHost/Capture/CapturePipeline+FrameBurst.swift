import Foundation

extension CapturePipeline {
    /// A switch moves the picture under a stream that sends a frame only when something changes: the slide, then the settled desktop, can both go unsent. Asking for a redraw every interval for a while makes the phone see the whole transition and end on the final picture.
    func streamFreshFrames(for duration: Duration, every interval: Duration) {
        let burst = Task { [weak self] in
            let deadline = ContinuousClock.now + duration
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard let self else { return }
                let engine = self.lock.withLock { self.runningEngine as? CaptureEngine }
                engine?.refreshFrame()
                try? await Task.sleep(for: interval)
            }
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let previous = frameBurst
            frameBurst = burst
            return previous
        }
        previous?.cancel()
    }
}

extension VideoCoordinator {
    func streamFreshFramesAfterSpaceSwitch() {
        pipeline.streamFreshFrames(for: .seconds(3), every: .milliseconds(120))
    }
}
