import Darwin
import Foundation
import MacCastKit

/// Narrow on purpose: CPU and memory are this process alone (kernel accounting) and network is counted by the streamer where bytes leave.
/// A value holding no timer: the window decides when it is looked at.
struct HostResourceSampler {
    /// nil for the first two seconds: a rate needs an interval, and zero would be unmeasured.
    private(set) var rates: ResourceRates?
    private(set) var memoryBytes: UInt64 = 0

    private var meter: ResourceMeter

    init(cores: Int = ProcessInfo.processInfo.activeProcessorCount) {
        meter = ResourceMeter(cores: cores)
    }

    /// bytesSent is passed in because the streamer owns that count.
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

    /// Without it a window left on another section comes back with a figure averaged over the unwatched period.
    mutating func reset() {
        meter.reset()
        rates = nil
    }

    // MARK: - The two numbers

    private static func read() -> (cpuSeconds: Double, memoryBytes: UInt64)? {
        guard let cpu = cpuSeconds() else { return nil }
        return (cpu, footprint() ?? residentBytes() ?? 0)
    }

    /// getrusage, not MACH_TASK_BASIC_INFO: on Darwin 27 its user_time and system_time stay at zero (measured) while returning KERN_SUCCESS, which reads as 0.0% forever. TASK_BASIC_INFO is frozen the same way.
    /// TASK_ABSOLUTETIME_INFO works but counts in mach absolute time (125/3 on Apple Silicon, 1/1 on Intel); a missing conversion reads as a plausible number.
    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// phys_footprint, not resident_size: IOSurface mappings from VideoToolbox and the compositor can be left out of resident size. It is also what Activity Monitor shows.
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

    /// Resident size: a slightly narrow fallback for a Mac that refuses the larger structure.
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
    /// On the sampler, not the view, so the capture probe prints the same strings.
    static func cpuPercent(_ rates: ResourceRates) -> String {
        percent(rates.cpuOfMachine)
    }

    /// Tiers rather than fixed precision, so a figure on a boundary does not flicker between 9.94% and 10%. Uses the locale like the byte figures beside it, and is not clamped at 1 because a multi-core burn legitimately exceeds one core.
    static func percent(_ fraction: Double) -> String {
        let value = max(0, fraction)
        switch value {
        case ..<0.01: return value.formatted(.percent.precision(.fractionLength(0...2)))
        case ..<0.1: return value.formatted(.percent.precision(.fractionLength(0...1)))
        default: return value.formatted(.percent.precision(.fractionLength(0)))
        }
    }

    static func memoryText(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .memory))
    }

    /// Decimal units, as networks are sold; memory uses binary. The two disagree by 7%.
    static func networkText(_ bytesPerSecond: Double) -> String {
        UInt64(max(0, bytesPerSecond).rounded()).formatted(.byteCount(style: .file)) + "/s"
    }
}
