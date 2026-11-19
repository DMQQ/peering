import Foundation
import os

private let streamLog = Logger(subsystem: "pl.dmq.peering", category: "streams")

/// Runs a ``StreamMux`` between two ends: a timer, the choice of carrier, and the hand-offs to whatever actually moves bytes. Everything happens on one serial queue, so the mux needs no lock and a frame sent from anywhere keeps its place in line.
public final class StreamTransport: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// One payload to put inside a ``MessageKind/stream`` frame on the control connection.
        public var sendOnControl: @Sendable (Data) -> Void
        /// One payload to seal as a ``MessageKind/stream`` datagram and send on the lane.
        public var sendOnLane: @Sendable (Data) -> Void
        public var laneIsLive: @Sendable () -> Bool
        /// A whole frame that arrived on one of the streams, in its stream's order.
        public var deliver: @Sendable (Frame) -> Void
        /// A stream's bytes were not frames: no repair fixes that, so the session ends.
        public var fail: @Sendable (Error) -> Void

        public init(
            sendOnControl: @escaping @Sendable (Data) -> Void,
            sendOnLane: @escaping @Sendable (Data) -> Void,
            laneIsLive: @escaping @Sendable () -> Bool,
            deliver: @escaping @Sendable (Frame) -> Void,
            fail: @escaping @Sendable (Error) -> Void
        ) {
            self.sendOnControl = sendOnControl
            self.sendOnLane = sendOnLane
            self.laneIsLive = laneIsLive
            self.deliver = deliver
            self.fail = fail
        }
    }

    public enum Failure: Error { case stopped }

    /// Timeouts in a row on the lane before it is left, and for how long, as the control pipe did.
    private static let timeoutsBeforeLeavingLane = 3
    private static let lanePenalty: Duration = .seconds(10)
    private static let tick: DispatchTimeInterval = .milliseconds(20)

    private let queue: DispatchQueue
    private let hooks: Hooks
    private var mux = StreamMux()
    private var carrier: StreamMux.Carrier = .reliable
    private var laneBannedUntil: ContinuousClock.Instant?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    public init(queue: DispatchQueue, hooks: Hooks) {
        self.queue = queue
        self.hooks = hooks
    }

    public func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
            source.setEventHandler { [weak self] in self?.pump() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            for completion in mux.takeAllCompletions() { completion(Failure.stopped) }
        }
    }

    /// False for a frame that does not travel on a stream: the caller sends it on the control connection as usual.
    @discardableResult
    public func send(_ frame: Frame, completion: StreamMux.Completion? = nil) -> Bool {
        guard StreamRouting.stream(for: frame) != nil else { return false }
        queue.async { [self] in
            guard !stopped else {
                completion?(Failure.stopped)
                return
            }
            mux.enqueue(frame, completion: completion)
            pump()
        }
        return true
    }

    /// A ``MessageKind/stream`` payload from either carrier.
    public func receive(_ payload: Data) {
        queue.async { [self] in
            guard !stopped else { return }
            let frames: [Frame]
            do {
                frames = try mux.receive(payload, now: .now)
            } catch {
                streamLog.error("a stream carried bytes that are not frames, so the session is ending: \(String(describing: error), privacy: .public)")
                hooks.fail(error)
                return
            }
            for frame in frames { hooks.deliver(frame) }
            pump()
        }
    }

    private func pump() {
        guard !stopped else { return }
        let now = ContinuousClock.now
        chooseCarrier(now: now)
        for payload in mux.outgoing(now: now, carrier: carrier) {
            if carrier == .lossy { hooks.sendOnLane(payload) } else { hooks.sendOnControl(payload) }
        }
        for completion in mux.takeCompleted() { completion(nil) }
    }

    private func chooseCarrier(now: ContinuousClock.Instant) {
        if carrier == .lossy, mux.consecutiveTimeouts >= Self.timeoutsBeforeLeavingLane {
            laneBannedUntil = now + Self.lanePenalty
        }
        let banned = laneBannedUntil.map { now < $0 } ?? false
        let wanted: StreamMux.Carrier = hooks.laneIsLive() && !banned ? .lossy : .reliable
        guard wanted != carrier else { return }
        carrier = wanted
        mux.carrierChanged()
        streamLog.notice("the streams moved to \(wanted == .lossy ? "the direct path" : "the control connection", privacy: .public)")
    }
}
