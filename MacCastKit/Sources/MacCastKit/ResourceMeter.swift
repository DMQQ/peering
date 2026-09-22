import Foundation

/// What this app costs the Mac, as a pair of readings rather than as a number.
///
/// **None of these figures is a number on its own.** A CPU percentage is a delta of CPU time
/// over a delta of wall clock, and a rate is the same shape, so one reading can only answer in
/// cumulative terms, like "eleven minutes of CPU since launch", which is not the question anybody
/// asks of a running app.
///
/// The arithmetic lives here rather than in the host's view, and it is here rather than beside
/// the sampler because these are the three cases that produce a plausible wrong number: the
/// first sample, which has nothing to subtract from; a counter that went backwards, which
/// subtracts to a negative; and an interval that is not what the timer said it was. A reading
/// that is wrong in any of those three looks exactly like a reading, which is why it is a type
/// with tests under it instead of four lines in a view.
public struct ResourceSample: Sendable, Equatable {
    /// User plus system CPU time charged to this process, in seconds, cumulative since launch.
    public var cpuSeconds: Double
    /// Resident size: the memory this process is accountable for right now.
    public var residentBytes: UInt64
    /// Bytes this app has put on the network, cumulative, counted where they are sent rather
    /// than where they are produced: see `VideoStreamer.Stats.bytesSent`.
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
    /// CPU as a share of **the whole machine**: 0.24 is this app holding a quarter of every
    /// core at once.
    ///
    /// Not a share of one core, which is the other way to say it and the way `top` and Activity
    /// Monitor say it. Both are honest and they disagree by a factor no reader would guess, so
    /// the split is: this is what the window prints, because "how much of my Mac is this using"
    /// is the question being asked, and ``cpuOfOneCore`` is what the report quotes, because it
    /// is the one a curious user can check against Activity Monitor.
    public var cpuOfMachine: Double
    /// The same work as a share of a single core, where 1.9 is 190%, which is the number
    /// Activity Monitor's own CPU column shows and is legitimately above 1 on a machine with
    /// more than one core. Derived from ``cpuOfMachine`` rather than measured separately, so
    /// that the two cannot drift apart.
    public var cpuOfOneCore: Double
    /// Bytes per second this app has sent, over the interval.
    public var bytesPerSecond: Double
}

/// Turns the cumulative counters into rates, and holds the last few seconds of them.
///
/// The smoothing is a mean of the per-interval rates rather than a total over the window, and
/// that is the resilient choice rather than the obvious one: a counter that reset partway
/// through the window poisons a total, while each interval's rate was computed from a pair that
/// had already been checked for a reset. When the intervals are even (which they are, a timer
/// asking for one) the two are the same figure anyway.
public struct ResourceMeter: Sendable {
    /// How many cores the machine has, so a share of them can be worked out. Clamped to at
    /// least one, because `activeProcessorCount` is the kind of value that is only ever wrong
    /// on the machine you cannot test on.
    public let cores: Int
    /// How many intervals the smoothed figure averages. Four seconds each would be a figure
    /// that has not caught up with what the user just did; thirty would be one that never
    /// moves. Five of a two-second timer is ten seconds of memory, which holds still enough to
    /// read and still shows a mosaic starting.
    public let smoothing: Int

    private var previous: ResourceSample?
    private var recent: [ResourceRates] = []

    public init(cores: Int, smoothing: Int = 5) {
        self.cores = max(1, cores)
        self.smoothing = max(1, smoothing)
    }

    /// Takes a reading and answers what happened since the last one.
    ///
    /// `nil` is a real answer and not a failure: on the first sample there is no interval to
    /// divide by, and on two samples taken in the same instant there is no interval either.
    /// Zero would be a figure the window would print as "idle", which is a different claim.
    @discardableResult
    public mutating func record(_ sample: ResourceSample) -> ResourceRates? {
        defer { previous = sample }
        guard let last = previous else { return nil }

        let seconds = sample.stamp - last.stamp
        guard seconds > 0, seconds.isFinite else { return nil }

        // CPU seconds per wall second, which is the number of cores held busy on average, and
        // therefore a share of exactly one of them.
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

    /// The intervals held, oldest first, for anything that wants the shape of the last minute
    /// rather than one figure out of it.
    public var recentRates: [ResourceRates] { recent }

    /// Forgets the baseline, for a sampler that was stopped and started again.
    ///
    /// Without this a window closed for an hour and reopened would compute its first interval
    /// across the hour, which is not wrong so much as meaningless: the process really did
    /// accumulate that CPU time, and none of it was spent doing anything the user was watching.
    public mutating func reset() {
        previous = nil
        recent.removeAll()
    }

    /// CPU seconds over one interval, never negative.
    ///
    /// A process's CPU time does not go backwards, so a negative delta is not a reading at all;
    /// it means the two samples did not come from the same process, or not from the same
    /// counter. Clamping at zero answers "nothing measurable happened", which is the only
    /// defensible thing left to say.
    private static func intervalCPU(from last: ResourceSample, to sample: ResourceSample) -> Double {
        max(0, sample.cpuSeconds - last.cpuSeconds)
    }

    /// Bytes over one interval, with a counter that reset read as a fresh start.
    ///
    /// The counters this is fed from are cumulative for the life of the process, but not
    /// unconditionally: a new streamer, a new session or a client detaching resets one, and a
    /// plain subtraction across that turns a busy second into a negative number. Zero would be
    /// the safe wrong answer here and the current reading is the better one: whatever the
    /// counter says now was accumulated since the reset, and a reset cannot have happened
    /// after the previous sample, so all of it belongs to this interval.
    private static func intervalBytes(from last: ResourceSample, to sample: ResourceSample) -> UInt64 {
        sample.bytesSent >= last.bytesSent ? sample.bytesSent - last.bytesSent : sample.bytesSent
    }
}
