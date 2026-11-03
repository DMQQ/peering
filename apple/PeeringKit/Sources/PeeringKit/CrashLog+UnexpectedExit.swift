import Darwin
import Foundation

extension CrashLog {
    /// Files one diagnostic, under the day it describes rather than the moment it arrived.
    static func store(diagnosticPayload data: Data) {
        guard let directory = directory(subject: subjectForStorage) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("metrickit-\(stamp).json")
        try? data.write(to: url)
        prune(directory, keeping: keep)
    }

    /// Set by ``install(subject:version:)``, because the callback arrives on MetricKit's own queue
    /// with no way to be told which app it is running in.
    private static var subjectForStorage: String {
        lock.withLock { storedSubject ?? Bundle.main.bundleIdentifier ?? "app" }
    }
}

// MARK: - Exits nothing could write down

/// Everything below exists for the deaths the handlers above cannot see: iOS ending the app for its
/// memory or for a blocked main thread (`SIGKILL`, which no code survives), and a stack overflow,
/// which used to leave the handler no stack to run on.
extension CrashLog {
    nonisolated(unsafe) private static var trail: [String] = []
    nonisolated(unsafe) private static var isForeground = false
    nonisolated(unsafe) private static var sampler: DispatchSourceTimer?
    private static let trailQueue = DispatchQueue(label: "pl.dmq.peering.crashlog.trail", qos: .utility)
    private static let trailLength = 30

    /// Tells the log whether the app is on screen.
    public static func setForeground(_ foreground: Bool) {
        trailQueue.async {
            isForeground = foreground
            if foreground {
                record("on screen")
                startSampling()
            } else {
                sampler?.cancel()
                sampler = nil
                if let file = lock.withLock({ runningFile }) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// Adds one line to the trail: a connection phase, a reconnect, a source picked.
    ///
    /// Cheap enough for events, never for frames: each call rewrites a small file.
    public static func note(_ event: String) {
        trailQueue.async { record(event) }
    }

    private static func record(_ event: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        trail.append("\(stamp)  \(event)  [\(memorySummary())]")
        if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
        writeTrail()
    }

    /// Every ten seconds on screen, because a leak climbs toward the memory limit between events.
    private static func startSampling() {
        guard sampler == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: trailQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { writeTrail() }
        timer.resume()
        sampler = timer
    }

    private static func writeTrail() {
        guard isForeground, let file = lock.withLock({ runningFile }) else { return }
        let text = (["memory now: \(memorySummary())", ""] + trail).joined(separator: "\n")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// What this process holds, and how far that is from the limit iOS kills at.
    private static func memorySummary() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "memory unknown" }
        let used = "\(info.phys_footprint / 1_048_576) MB used"
        #if os(iOS)
        return "\(used), \(os_proc_available_memory() / 1_048_576) MB left"
        #else
        return used
        #endif
    }

    static func fileUnexpectedExit(_ running: URL, caughtCrash: Bool, into directory: URL) {
        defer { try? FileManager.default.removeItem(at: running) }
        guard !caughtCrash, let trail = try? String(contentsOf: running, encoding: .utf8) else { return }
        let when = (try? running.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let stamp = ISO8601DateFormatter().string(from: when).replacingOccurrences(of: ":", with: "-")
        let text = """
            UNEXPECTED EXIT
            The app stopped while on screen and left no crash report. Likely causes: iOS ended it \
            for memory or for a blocked main thread, or it was stopped from Xcode. The time is the \
            last entry below, within ten seconds.

            \(trail)
            """
        try? text.write(
            to: directory.appendingPathComponent("crash-\(stamp)-exit.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// A stack of its own for the signal handler, on the thread that installs it (the main
    /// thread). Without it a stack overflow faults again inside the handler and nothing is written.
    static func installAlternateStack() {
        let size = Int(SIGSTKSZ)
        guard let memory = malloc(size) else { return }
        var stack = stack_t(ss_sp: memory, ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
    }

    static func store(exitSummary text: String) {
        guard let directory = directory(subject: subjectForStorage) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? text.write(
            to: directory.appendingPathComponent("metrickit-exits-\(stamp).txt"),
            atomically: true,
            encoding: .utf8
        )
        prune(directory, keeping: keep)
    }
}
