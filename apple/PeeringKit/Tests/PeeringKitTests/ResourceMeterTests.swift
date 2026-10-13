import XCTest
@testable import PeeringKit

/// Every failure here yields a plausible-looking number (missing interval, negative rate after a counter reset, a share clamped at one core), so each is asserted.
final class ResourceMeterTests: XCTestCase {
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

        XCTAssertEqual(rates?.cpuOfMachine ?? 0, 0.375, accuracy: 0.0001)
        XCTAssertEqual(rates?.cpuOfOneCore ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(rates?.bytesPerSecond ?? 0, 2_000, accuracy: 0.0001)
    }

    /// The mosaic case: more than one core in use, which a clamp at 100% would hide.
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

    /// systemUptime stops during sleep: two samples with no time between them but a large CPU charge.
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

    /// A new streamer resets its byte counter, but that interval still carried traffic.
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

        // One core, not zero: a zero core count would divide to an infinite share.
        XCTAssertEqual(rates?.cpuOfOneCore ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(rates?.cpuOfMachine ?? 0, 1, accuracy: 0.0001)
    }

    func testTheSmoothedFigureIsTheMeanOfTheIntervalsHeld() {
        var meter = meter(cores: 1)
        meter.record(sample(cpu: 0, bytes: 0, at: 0))
        meter.record(sample(cpu: 2, bytes: 1_000, at: 2))
        meter.record(sample(cpu: 2, bytes: 1_000, at: 4))

        XCTAssertEqual(meter.smoothed?.cpuOfMachine ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(meter.smoothed?.bytesPerSecond ?? 0, 250, accuracy: 0.0001)
    }

    func testTheSmoothedFigureDropsIntervalsBeyondItsWindow() {
        var meter = meter(cores: 1, smoothing: 2)
        meter.record(sample(cpu: 0, at: 0))
        meter.record(sample(cpu: 10, at: 2))
        meter.record(sample(cpu: 10, at: 4))
        meter.record(sample(cpu: 10, at: 6))

        XCTAssertEqual(meter.recentRates.count, 2)
        XCTAssertEqual(meter.smoothed?.cpuOfMachine ?? 0, 0, accuracy: 0.0001)
    }

    func testResetDropsTheBaseline() {
        var meter = meter()
        meter.record(sample(cpu: 10, at: 100))
        meter.reset()

        XCTAssertNil(meter.record(sample(cpu: 900, at: 3_700)))
        XCTAssertNil(meter.smoothed)
    }
}
