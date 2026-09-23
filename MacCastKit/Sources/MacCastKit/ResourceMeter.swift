import Foundation

/// What this app costs the Mac, as a pair of readings rather than as a number.
///
/// A CPU percentage is a delta of CPU time over a delta of wall clock, and a rate is the same
/// shape, so one reading can only answer in cumulative terms.
///
/// The arithmetic is a type with tests under it rather than four lines in a view, because three
/// cases produce a plausible wrong number: the first sample, a counter that went backwards, and an
/// interval that is not what the timer said it was.
public struct ResourceSample: Sendable, Equatable {
    /// User plus system CPU time charged to this process, in seconds, cumulative since launch.
    public var cpuSeconds: Double
    /// Resident size: the memory this process is accountable for right now.
    public var residentBytes: UInt64
    /// Bytes this app has put on the network, cumulative, counted where they are sent rather than
    /// where they are produced. See `VideoStreamer.Stats.bytesSent`.
    public var bytesSent: UInt64
    /// A monotonic clock, in seconds. Which monotonic clock does not matter, because only the
    /// difference between two readings is ever used; a wall clock does, because it steps.
    public var stamp: Double

    public init(cpuSeconds: Double, residentBytes: UInt64, bytesSent: UInt64, stamp: Double) {
        self.cpuSeconds = cpuSeconds
        self.residentBytes = residentBytes
        self.bytesSent = bytesSent
        self.stamp = stamp
    }
}

/// The cost between two samples, as the figures a window prints.
public struct ResourceRates: Sendable, Equatable {
    /// CPU as a share of the whole machine: 0.24 is this app holding a quarter of every core at
    /// once.
    ///
    /// Not a share of one core, which is how `top` and Activity Monitor say it: this is what the
    /// window prints, because "how much of my Mac is this using" is the question being asked.
    public var cpuOfMachine: Double
    /// The same work as a share of a single core, where 1.9 is 190%, which is the number Activity
    /// Monitor's own CPU column shows. Derived from ``cpuOfMachine`` rather than measured
    /// separately, so the two cannot drift apart.
    public var cpuOfOneCore: Double
    /// Bytes per second this app has sent, over the interval.
    public var bytesPerSecond: Double
}

/// Turns the cumulative counters into rates, and holds the last few seconds of them.
///
/// The smoothing is a mean of the per-interval rates rather than a total over the window: a counter
/// that reset partway through poisons a total, while each interval's rate came from a pair already
/// checked for a reset.
public struct ResourceMeter: Sendable {
    /// How many cores the machine has. Clamped to at least one, because `activeProcessorCount` is
    /// the kind of value that is only ever wrong on the machine you cannot test on.
    public let cores: Int
    /// How many intervals the smoothed figure averages: five of a two-second timer is ten seconds
    /// of memory, which holds still enough to read and still shows a mosaic starting.
    public let smoothing: Int

    private var previous: ResourceSample?
    private var recent: [ResourceRates] = []

    public init(cores: Int, smoothing: Int = 5) {
        self.cores = max(1, cores)
        self.smoothing = max(1, smoothing)
    }

    /// Takes a reading and answers what happened since the last one.
    ///
    /// `nil` is a real answer and not a failure: on the first sample there is no interval to divide
    /// by. Zero would be a figure the window would print as "idle", which is a different claim.
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

    /// The last few intervals as one figure, or `nil` before there is one to average.
    public var smoothed: ResourceRates? {
        guard !recent.isEmpty else { return nil }
        let count = Double(recent.count)
        return ResourceRates(
            cpuOfMachine: recent.reduce(0) { $0 + $1.cpuOfMachine } / count,
            cpuOfOneCore: recent.reduce(0) { $0 + $1.cpuOfOneCore } / count,
            bytesPerSecond: recent.reduce(0) { $0 + $1.bytesPerSecond } / count
        )
    }

    /// The intervals held, oldest first, for anything that wants the shape rather than one figure.
    public var recentRates: [ResourceRates] { recent }

    /// Forgets the baseline, for a sampler that was stopped and started again: a window closed for
    /// an hour would otherwise compute its first interval across the hour.
    public mutating func reset() {
        previous = nil
        recent.removeAll()
    }

    /// CPU seconds over one interval, never negative: a process's CPU time does not go backwards,
    /// so a negative delta means the two samples came from different counters, and zero is the only
    /// defensible reading left.
    private static func intervalCPU(from last: ResourceSample, to sample: ResourceSample) -> Double {
        max(0, sample.cpuSeconds - last.cpuSeconds)
    }

    /// Bytes over one interval, with a counter that reset read as a fresh start.
    ///
    /// The counters are cumulative for the life of the process but not unconditionally: a new
    /// streamer, a new session or a client detaching resets one, and a plain subtraction across
    /// that turns a busy second into a negative number. The current reading is better than zero,
    /// because a reset cannot have happened after the previous sample, so all of it belongs here.
    private static func intervalBytes(from last: ResourceSample, to sample: ResourceSample) -> UInt64 {
        sample.bytesSent >= last.bytesSent ? sample.bytesSent - last.bytesSent : sample.bytesSent
    }
}
