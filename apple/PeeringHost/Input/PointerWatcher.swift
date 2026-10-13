import CoreGraphics
import Foundation
import RemoteCore

/// Reports where the Mac's pointer is when a hand on the Mac moved it. The joystick sends the phone only a delta, so without this its drawn cursor keeps the spot it last estimated.
nonisolated final class PointerWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.pointer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastReported: CGPoint?

    /// Under this the pointer is where the injector last put it; the rounding of a point to a pixel is not a hand.
    private static let injectedTolerance: CGFloat = 2

    func start(
        transform: @escaping @Sendable () -> InputTransform?,
        lastInjected: @escaping @Sendable () -> CGPoint,
        onMove: @escaping @Sendable (NormalizedPoint) -> Void
    ) {
        queue.async { [self] in
            guard timer == nil else { return }
            lastReported = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                self?.poll(transform: transform(), lastInjected: lastInjected(), onMove: onMove)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastReported = nil
        }
    }

    private func poll(
        transform: InputTransform?,
        lastInjected: CGPoint,
        onMove: (NormalizedPoint) -> Void
    ) {
        guard let transform, let location = CGEvent(source: nil)?.location else { return }
        // First poll records the baseline: only a move the user makes should pull the phone's cursor.
        guard let previous = lastReported else {
            lastReported = location
            return
        }
        guard Self.distance(location, previous) > Self.injectedTolerance else { return }
        lastReported = location
        guard Self.distance(location, lastInjected) > Self.injectedTolerance else { return }
        onMove(transform.normalizedPoint(fromGlobal: location))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
