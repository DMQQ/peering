import Foundation

/// Three cases produce a plausible wrong number: the first sample, a counter that went backwards, and an interval that is not what the timer said.
public struct ResourceSample: Sendable, Equatable {
    public var cpuSeconds: Double
    public var residentBytes: UInt64
    /// Bytes sent, cumulative. See `VideoStreamer.Stats.bytesSent`.
    public var bytesSent: UInt64
    /// Monotonic seconds; only differences are used, and a wall clock would step.
    public var stamp: Double

    public init(cpuSeconds: Double, residentBytes: UInt64, bytesSent: UInt64, stamp: Double) {
        self.cpuSeconds = cpuSeconds
        self.residentBytes = residentBytes
        self.bytesSent = bytesSent
        self.stamp = stamp
    }
}

public struct ResourceRates: Sendable, Equatable {
    /// CPU as a share of the whole machine (0.24 is a quarter of every core), not of one core as `top` says it.
    public var cpuOfMachine: Double
    /// A share of a single core (1.9 is 190%), as Activity Monitor shows. Derived from ``cpuOfMachine``.
    public var cpuOfOneCore: Double
    public var bytesPerSecond: Double
}

/// The smoothing is a mean of per-interval rates, because a counter reset poisons a total.
public struct ResourceMeter: Sendable {
    /// Clamped to at least one core.
    public let cores: Int
    public let smoothing: Int

    private var previous: ResourceSample?
    private var recent: [ResourceRates] = []

    public init(cores: Int, smoothing: Int = 5) {
        self.cores = max(1, cores)
        self.smoothing = max(1, smoothing)
    }

    /// `nil` on the first sample (no interval); zero would print as "idle".
    @discardableResult
    public mutating func record(_ sample: ResourceSample) -> ResourceRates? {
        defer { previous = sample }
        guard let last = previous else { return nil }

        let seconds = sample.stamp - last.stamp
        guard seconds > 0, seconds.isFinite else { return nil }

        // CPU seconds per wall second: the cores held busy on average, so a share of exactly one.
        let coresBusy = Self.intervalCPU(from: last, to: sample) / seconds
        let rates = ResourceRates(
            // Through one division rather than a second subtraction, so the two shares cannot
            // disagree about the interval they were measured over.
            cpuOfMachine: coresBusy / Double(cores),
            cpuOfOneCore: coresBusy,
            bytesPerSecond: Double(Self.intervalBytes(from: last, to: sample)) / seconds
        )

        recent.append(rates)
        if recent.count > smoothing { recent.removeFirst(recent.count - smoothing) }
        return rates
    }

    public var smoothed: ResourceRates? {
        guard !recent.isEmpty else { return nil }
        let count = Double(recent.count)
        return ResourceRates(
            cpuOfMachine: recent.reduce(0) { $0 + $1.cpuOfMachine } / count,
            cpuOfOneCore: recent.reduce(0) { $0 + $1.cpuOfOneCore } / count,
            bytesPerSecond: recent.reduce(0) { $0 + $1.bytesPerSecond } / count
        )
    }

    public var recentRates: [ResourceRates] { recent }

    /// Forgets the baseline, so a restarted sampler does not compute across the gap.
    public mutating func reset() {
        previous = nil
        recent.removeAll()
    }

    /// Never negative: a negative delta means the samples came from different counters.
    private static func intervalCPU(from last: ResourceSample, to sample: ResourceSample) -> Double {
        max(0, sample.cpuSeconds - last.cpuSeconds)
    }

    /// A counter that reset is read as a fresh start: the current reading belongs to this interval, where plain subtraction goes negative.
    private static func intervalBytes(from last: ResourceSample, to sample: ResourceSample) -> UInt64 {
        sample.bytesSent >= last.bytesSent ? sample.bytesSent - last.bytesSent : sample.bytesSent
    }
}
