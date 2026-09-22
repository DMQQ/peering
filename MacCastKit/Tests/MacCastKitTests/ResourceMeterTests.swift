import XCTest
@testable import MacCastKit

/// The arithmetic between two readings of this app's own cost.
///
/// It is worth its own file because every failure mode here produces a number that looks like
/// a number: a first sample that divides by an interval it does not have, a counter that reset
/// and subtracts to a negative rate, an interval the timer did not honour, a share of one core
/// silently clamped at one core because the figure looked too big to be true. None of those
/// shows up as an error on screen, which is exactly why they are asserted here.
final class ResourceMeterTests: XCTestCase {
    /// Four cores, two-second intervals, so the figures below are ones that can be checked by
    /// hand: a quarter of a core for a second is 0.125 of this machine.
    private func meter(cores: Int = 4, smoothing: Int = 5) -> ResourceMeter {
        ResourceMeter(cores: cores, smoothing: smoothing)
    }

    private func sample(
        cpu: Double = 0,
        resident: UInt64 = 100_000_000,
        bytes: UInt64 = 0,
        at stamp: Double
    ) -> ResourceSample {
        ResourceSample(cpuSeconds: cpu, residentBytes: resident, bytesSent: bytes, stamp: stamp)
    }

    func testTheFirstSampleIsNotARate() {
        var meter = meter()
        XCTAssertNil(meter.record(sample(cpu: 30, bytes: 4000, at: 100)))
        XCTAssertNil(meter.smoothed)
    }

    func testTheSecondSampleMeasuresTheInterval() {
        var meter = meter()
        meter.record(sample(cpu: 10, bytes: 1_000, at: 100))
        let rates = meter.record(sample(cpu: 13, bytes: 5_000, at: 102))

        // Three CPU seconds over four cores in two seconds: the app held 37.5% of the whole
        // machine, which is 1.5 cores at once.
        XCTAssertEqual(rates?.cpuOfMachine ?? 0, 0.375, accuracy: 0.0001)
        XCTAssertEqual(rates?.cpuOfOneCore ?? 0, 1.5, accuracy: 0.0001)
        // 4 KB over two seconds.
        XCTAssertEqual(rates?.bytesPerSecond ?? 0, 2_000, accuracy: 0.0001)
    }

    /// The mosaic case, and the one a clamp would hide. Six capture streams and an encoder can
    /// hold more than one core at once, and a figure that stopped at 100% would read as "using
    /// a core" whether it was using one or four.
    func testAShareOfOneCoreGoesAboveOne() {
        var meter = meter(cores: 8)
        meter.record(sample(cpu: 100, at: 0))
        let rates = meter.record(sample(cpu: 106, at: 2))

        XCTAssertEqual(rates?.cpuOfOneCore ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(rates?.cpuOfMachine ?? 0, 0.375, accuracy: 0.0001)
    }

    func testTheSameInstantIsNotAnInterval() {
        var meter = meter()
        meter.record(sample(cpu: 10, at: 100))
        XCTAssertNil(meter.record(sample(cpu: 40, at: 100)))
    }

    /// `systemUptime` does not advance while the Mac is asleep, so a window left open across a
    /// lid close asks for exactly this: two samples, no time between them, and a large amount
    /// of CPU charged to the app for having been woken up.
    func testAClockThatWentBackwardsIsNotAnInterval() {
        var meter = meter()
        meter.record(sample(cpu: 10, at: 100))
        XCTAssertNil(meter.record(sample(cpu: 40, at: 99)))
    }

    func testCPUThatWentBackwardsReadsAsNothing() {
        var meter = meter()
        meter.record(sample(cpu: 10, at: 100))
        let rates = meter.record(sample(cpu: 2, at: 102))

        XCTAssertEqual(rates?.cpuOfMachine ?? 1, 0)
        XCTAssertEqual(rates?.bytesPerSecond ?? 1, 0)
    }

    /// A streamer detached and a new one started, so its byte counter went back to zero. The
    /// interval still carried traffic, since the fresh counter is that traffic, and reporting
    /// zero would be a window that says a busy second cost nothing.
    func testACounterThatResetReadsAsTheTrafficSinceTheReset() {
        var meter = meter()
        meter.record(sample(bytes: 900_000, at: 100))
        let rates = meter.record(sample(bytes: 300, at: 102))

        XCTAssertEqual(rates?.bytesPerSecond ?? 0, 150, accuracy: 0.0001)
    }

    func testAMachineWithNoCoresIsStillAMachine() {
        var meter = meter(cores: 0)
        meter.record(sample(cpu: 0, at: 0))
        let rates = meter.record(sample(cpu: 1, at: 1))

        // One core, not zero: dividing by a core count of zero would be an infinite share of a
        // machine that certainly has at least one core in it.
        XCTAssertEqual(rates?.cpuOfOneCore ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(rates?.cpuOfMachine ?? 0, 1, accuracy: 0.0001)
    }

    func testTheSmoothedFigureIsTheMeanOfTheIntervalsHeld() {
        var meter = meter(cores: 1)
        meter.record(sample(cpu: 0, bytes: 0, at: 0))
        meter.record(sample(cpu: 2, bytes: 1_000, at: 2))
        meter.record(sample(cpu: 2, bytes: 1_000, at: 4))

        // Two intervals: 2 CPU seconds over 2 seconds, and none over the same. The mean is
        // half of that, and the mean is what keeps a figure from flickering.
        XCTAssertEqual(meter.smoothed?.cpuOfMachine ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(meter.smoothed?.bytesPerSecond ?? 0, 250, accuracy: 0.0001)
    }

    func testTheSmoothedFigureDropsIntervalsBeyondItsWindow() {
        var meter = meter(cores: 1, smoothing: 2)
        meter.record(sample(cpu: 0, at: 0))
        meter.record(sample(cpu: 10, at: 2))
        meter.record(sample(cpu: 10, at: 4))
        meter.record(sample(cpu: 10, at: 6))

        // Three intervals have been seen and only the last two are held, so the spike in the
        // first one stops being part of the figure rather than pulling it up forever.
        XCTAssertEqual(meter.recentRates.count, 2)
        XCTAssertEqual(meter.smoothed?.cpuOfMachine ?? 0, 0, accuracy: 0.0001)
    }

    /// Closing the window and opening it an hour later. The baseline is from the earlier
    /// visit, and the interval across it is an hour of nothing rather than a reading.
    func testResetDropsTheBaseline() {
        var meter = meter()
        meter.record(sample(cpu: 10, at: 100))
        meter.reset()

        XCTAssertNil(meter.record(sample(cpu: 900, at: 3_700)))
        XCTAssertNil(meter.smoothed)
    }
}
