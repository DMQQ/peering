import Darwin
import Foundation
import MacCastKit

/// What this app costs the Mac, read from this process and from nowhere else.
///
/// **The whole value of these figures is that they are narrow.** Everything else a window could
/// say about CPU, memory and network is about the Mac, which the user is also using for their
/// own work, and a number that included the browser and the compiler would answer nothing when
/// the question is "what is Peering costing me". So the CPU and memory halves are the kernel's
/// own accounting of this process alone, and the network half is counted by the streamer where
/// the bytes actually leave: see `VideoStreamer.Stats`. The cheap alternative, summing the
/// machine's interface counters, is a real measurement of the wrong thing, which is the kind of
/// figure that is worse than none at all.
///
/// It is a value rather than an object so that the window can hold it in `@State` and drop it
/// with the window, and it deliberately holds no timer of its own: the thing that decides when
/// a window is being looked at is the window.
struct HostResourceSampler {
    /// CPU and network as rates, or `nil` until there are two readings to subtract.
    ///
    /// Nil for the first two seconds and that is a real answer rather than a slow start: a rate
    /// needs an interval, and a zero printed in the meantime would be a claim about the app that
    /// nobody has measured.
    private(set) var rates: ResourceRates?
    /// The memory this process is accountable for, as of the last reading.
    private(set) var memoryBytes: UInt64 = 0

    private var meter: ResourceMeter

    init(cores: Int = ProcessInfo.processInfo.activeProcessorCount) {
        meter = ResourceMeter(cores: cores)
    }

    /// Takes one reading and folds it into the figure the window shows.
    ///
    /// Two syscalls and one subtraction, on a timer, while the encoder has a queue of frames to
    /// keep up with. That is the whole budget, and it is measurable: the probe prints it. If
    /// this ever needs more than that, it has stopped being something that can run beside a
    /// video pipeline.
    ///
    /// `bytesSent` is passed in rather than read here because the streamer owns that count and
    /// the window already has it; the sampler is not the second place that decides what counts
    /// as this app's traffic.
    mutating func sample(bytesSent: UInt64, at stamp: Double = ProcessInfo.processInfo.systemUptime) {
        guard let reading = Self.read() else { return }
        memoryBytes = reading.memoryBytes
        meter.record(
            ResourceSample(
                cpuSeconds: reading.cpuSeconds,
                residentBytes: reading.memoryBytes,
                bytesSent: bytesSent,
                stamp: stamp
            )
        )
        rates = meter.smoothed
    }

    /// Drops the readings held, for a sampler that was stopped and started again.
    ///
    /// Without it, a window left on another section for ten minutes would come back with a
    /// first figure averaged across the ten minutes nobody was looking at, which is true and is
    /// about a period whose length the reader has no way to know.
    mutating func reset() {
        meter.reset()
        rates = nil
    }

    // MARK: - The two numbers

    /// This process's CPU time and memory, or nil if the kernel would not say.
    ///
    /// Two different APIs, because the obvious single one does not work on this system (see
    /// ``cpuSeconds()``), and two different flavours' worth of patience about the memory (see
    /// ``footprint()``).
    private static func read() -> (cpuSeconds: Double, memoryBytes: UInt64)? {
        guard let cpu = cpuSeconds() else { return nil }
        return (cpu, footprint() ?? residentBytes() ?? 0)
    }

    /// User plus system CPU time for this process, from `getrusage`, and not from `task_info`.
    ///
    /// **`MACH_TASK_BASIC_INFO` is the API whose shape says it is right and whose numbers are
    /// frozen.** It reports `user_time` and `system_time` and answers `KERN_SUCCESS`, and on
    /// this macOS (Darwin 27) neither field moves: measured here, two seconds of deliberately
    /// burning four threads moved them by exactly zero, while the same interval moved
    /// `getrusage` by 1.9985 seconds. That is the worst shape a wrong reading can have, because
    /// a stub value reads as "0.0% of the machine" forever, which on this panel is not a
    /// failure but the best possible news. `TASK_BASIC_INFO`, the older flavour of the same
    /// call, is frozen identically.
    ///
    /// `getrusage` is public POSIX and hands back plain seconds, which is the second thing it
    /// buys: the flavour that does work, `TASK_ABSOLUTETIME_INFO`, counts in mach absolute
    /// time, whose conversion is 125/3 on Apple Silicon and 1/1 on Intel, and a missing
    /// conversion is a factor of 24 that reads as a plausible number either way.
    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        // Together rather than apart: they are a curiosity separately, and the ratio of their
        // sum to the wall clock is the share of the machine the panel prints.
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The memory this process is accountable for, in the number Activity Monitor would show.
    ///
    /// `phys_footprint` rather than `resident_size`, and for this app the two are not close:
    /// VideoToolbox's frames and the compositor's surfaces live in IOSurfaces, which are IOKit
    /// mappings, and a resident size can leave most of them out. Understating what a video
    /// pipeline holds, on the one panel whose job is to reassure somebody that it is not heavy,
    /// is the one direction this must not be wrong in. Footprint is also what Activity Monitor
    /// shows, so a user who goes to check finds the same number rather than a smaller one.
    private static func footprint() -> UInt64? {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(vm.phys_footprint)
    }

    /// A memory figure that is slightly narrow rather than no memory figure at all, for a Mac
    /// that refuses the larger structure above. This part of `task_info` does work: the same
    /// frozen struct reports a live resident size, which is what makes its dead CPU fields so
    /// easy to miss.
    private static func residentBytes() -> UInt64? {
        var basic = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(basic.resident_size)
    }
}

// MARK: - The figures as words

extension HostResourceSampler {
    /// These are on the sampler rather than in the view, and for one reason: the capture probe
    /// compiles this file and prints the very same strings, so a probe run is a reading of what
    /// the window would say rather than a second implementation of it that agrees today.
    static func cpuPercent(_ rates: ResourceRates) -> String {
        percent(rates.cpuOfMachine)
    }

    /// A percentage with the decimal in it only where the decimal is the message.
    ///
    /// Three tiers, and each one is a reading this app actually produces: a per cent, which is
    /// what a session costs and where a decimal is noise; a tenth of a per cent, which is an
    /// idle window being looked at, and where one decimal is the difference between "0.4%" and
    /// a figure that looks like it failed to load; and a hundredth, which is an app nobody has
    /// connected to and where two decimals keep a small real figure from being rounded into
    /// nothing. Below even that "0%" is the honest answer rather than a rounding error.
    ///
    /// Tiers rather than one fixed precision because a fixed one flickers: a figure sitting on
    /// a boundary would print "9.94%" and then "10%" two seconds later, which is a row of
    /// numbers twitching for no reason the reader can see.
    ///
    /// Handed to the locale rather than to `String(format:)`, and that is not decoration either:
    /// the byte figures beside it are already the locale's, and one tile printing "0.4" next to
    /// another printing "2,4 MB" is a window that looks like two programs.
    ///
    /// Deliberately not clamped at 1: the share of one core legitimately goes above it, and a
    /// clamp here would print a four-core burn as a hundred per cent of one.
    static func percent(_ fraction: Double) -> String {
        let value = max(0, fraction)
        switch value {
        case ..<0.01: return value.formatted(.percent.precision(.fractionLength(0...2)))
        case ..<0.1: return value.formatted(.percent.precision(.fractionLength(0...1)))
        default: return value.formatted(.percent.precision(.fractionLength(0)))
        }
    }

    /// The memory this app holds, in the units Activity Monitor would show it in.
    static func memoryText(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .memory))
    }

    /// A rate, in the decimal units a network is sold in rather than the binary ones memory is
    /// measured in. Both conventions are current and they disagree by 7%, so the choice is
    /// made by subject rather than by which looks tidier.
    static func networkText(_ bytesPerSecond: Double) -> String {
        UInt64(max(0, bytesPerSecond).rounded()).formatted(.byteCount(style: .file)) + "/s"
    }
}
