import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

/// Where a crash is written down, by the two things that can write one.
public enum CrashLog {
    /// One thing that went wrong, and when.
    public struct Entry: Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case crash
            case diagnostic
        }

        public let id: String
        public let kind: Kind
        public let date: Date
        /// The whole file, as written. Kept as text because the point is to be read.
        public let text: String
        public let url: URL
    }

    // MARK: - Where it goes

    /// The directory every file here lives in, created on demand.
    private static func directory(subject: String) -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = base
            .appendingPathComponent(subject, isDirectory: true)
            .appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// What ``install(subject:version:)`` was told, for the MetricKit callback to file under. It
    /// arrives on MetricKit's own queue with nothing to say which app it is running in.
    nonisolated(unsafe) private static var storedSubject: String?
    nonisolated(unsafe) private static var runningFile: URL?
    private static let lock = NSLock()

    /// How many of each kind are kept. Enough to see a pattern, few enough that this never becomes
    /// something a person has to manage.
    private static let keep = 10

    // MARK: - Installing

    /// Puts the handlers in and subscribes to MetricKit. Called once, as early as the app can.
    public static func install(subject: String, version: String? = nil) {
        let version = version ?? bundleVersion
        guard let directory = directory(subject: subject) else { return }
        let pending = directory.appendingPathComponent("last-crash.txt")

        // **The file the last run left behind becomes a dated report, before anything can overwrite
        // it.** This is the whole of how a launch crash survives: the run that died wrote it and
        // could not do anything else, and the run that has just started is the one that can file
        // it. Its modification date is when the crash happened, which is why no clock is read in
        let caught = archive(pending, into: directory)
        let running = directory.appendingPathComponent("running.txt")
        fileUnexpectedExit(running, caughtCrash: caught, into: directory)
        prune(directory, keeping: keep)

        lock.withLock {
            storedSubject = subject
            runningFile = running
        }
        prepareHandlerState(pending: pending, subject: subject, version: version)

        installExceptionHandler()
        installAlternateStack()

        for signalNumber in handledSignals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: handleSignal)
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
        }

        #if canImport(MetricKit)
        MXMetricManager.shared.add(metricCollector)
        #endif
    }

    /// `1.2.3 (456)`, or whatever the bundle has. Both halves, because this app's build number is a
    /// date and the version is the same date: a report that said only one of them would be
    /// ambiguous between two builds of the same day.
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    /// Files the last run's crash, and says whether there was one.
    @discardableResult
    private static func archive(_ pending: URL, into directory: URL) -> Bool {
        guard let text = try? String(contentsOf: pending, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try? FileManager.default.removeItem(at: pending)
            return false
        }

        // Dated by the file's own modification time rather than by now: the file was written at the
        // moment of the crash, and this runs at the next launch.
        let when = (try? pending.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let stamp = ISO8601DateFormatter().string(from: when)
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("crash-\(stamp).txt")
        try? text.write(to: destination, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: pending)
        return true
    }

    /// Drops the oldest reports of both kinds until `keep` of each are left.
    private static func prune(_ directory: URL, keeping keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for prefix in ["crash-", "metrickit-"] {
            let matching = files
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { left, right in
                    let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return l > r
                }
            for stale in matching.dropFirst(keep) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    // MARK: - Reading

    public static func entries(subject: String) -> [Entry] {
        guard let directory = directory(subject: subject) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return files.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            let kind: Entry.Kind
            if name.hasPrefix("crash-") {
                kind = .crash
            } else if name.hasPrefix("metrickit-") {
                kind = .diagnostic
            } else {
                return nil
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Entry(id: name, kind: kind, date: date, text: text, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    public static func clear(subject: String) {
        guard let directory = directory(subject: subject) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// The first line of the newest crash, for a row that has no space for the rest.
    public static func headline(of entry: Entry) -> String {
        entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "crash"
    }
}

// MARK: - The handler

/// The signals worth catching. `SIGKILL` is absent on purpose: the watchdog and the system kill the
/// process rather than crashing it, and nothing in the process is given the chance to run. That is
/// the half MetricKit covers and this half cannot.
private let handledSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

/// A C string per handled signal, so the handler has something to write without formatting it.
nonisolated(unsafe) private var signalHeaders: [UnsafeMutablePointer<CChar>?] =
    Array(repeating: nil, count: Int(NSIG))

nonisolated(unsafe) private var commonHeader: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var pendingPath: UnsafeMutablePointer<CChar>?

/// The same file as ``pendingPath``, as something Swift can open.
nonisolated(unsafe) private var exceptionLogURL: URL?

/// Writes an uncaught exception where the next launch will file it.
private func installExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let text = """
            EXCEPTION \(exception.name.rawValue)
            \(exception.reason ?? "no reason given")
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
        if let url = exceptionLogURL { append(text, to: url) }
    }
}

private func prepareHandlerState(pending: URL, subject: String, version: String) {
    for pointer in signalHeaders where pointer != nil { free(pointer) }
    free(commonHeader)
    free(pendingPath)

    let process = ProcessInfo.processInfo
    let common = """
        subject: \(subject)
        version: \(version)
        os: \(process.operatingSystemVersionString)
        launch: \(ISO8601DateFormatter().string(from: Date()))

        """
    commonHeader = strdup(common)
    pendingPath = strdup(pending.path)
    exceptionLogURL = pending
    signalHeaders = Array(repeating: nil, count: Int(NSIG))
    for number in handledSignals {
        signalHeaders[Int(number)] = strdup("SIGNAL \(number) \(name(of: number))\n")
    }
}

private func name(of signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGABRT: return "(abort)"
    case SIGSEGV: return "(bad memory access)"
    case SIGBUS: return "(bus error)"
    case SIGILL: return "(illegal instruction)"
    case SIGFPE: return "(arithmetic)"
    case SIGTRAP: return "(trap)"
    default: return ""
    }
}

/// Writes what happened and lets the process die.
private func handleSignal(_ signalNumber: Int32) {
    let header = signalNumber < Int32(NSIG) ? signalHeaders[Int(signalNumber)] : nil
    // `_exit` rather than `exit`: the latter runs atexit handlers and flushes streams, none of
    // which is safe from a signal context. This is the path taken when install never ran, so there
    // is nothing to write.
    guard let path = pendingPath else { _exit(signalNumber) }

    let descriptor = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
    if descriptor >= 0 {
        if let commonHeader { write(descriptor, commonHeader, strlen(commonHeader)) }
        if let header { write(descriptor, header, strlen(header)) }

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, descriptor)

        let blank = "\n"
        write(descriptor, blank, 1)
        close(descriptor)
    }

    // Re-raise with the default handler so the crash still looks like a crash: the system's own
    // reporting, and any debugger attached, carry on as they would have.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Appends a string normally, for the uncaught-exception handler, which does not run in a signal
/// context and can therefore use Swift.
private func append(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

// MARK: - MetricKit

#if canImport(MetricKit)
/// Apple's own diagnostics, which arrive about a day after the fact and cover what a signal handler
/// cannot: watchdog kills, hangs, and CPU and disk exceptions.
private let metricCollector = MetricKitCollector()

/// `@unchecked Sendable` because it has no state to race on: it is a name for the two callbacks and
/// nothing else. `MXMetricManager` holds its subscriber weakly, which is why `install` keeps this
/// one alive itself.
private final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            CrashLog.store(diagnosticPayload: payload.jsonRepresentation())
        }
    }

    /// Only the exit counts: a memory-limit or watchdog kill is not a crash to MetricKit and
    /// reaches the app nowhere else.
    func didReceive(_ payloads: [MXMetricPayload]) {
        #if os(iOS)
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics?.foregroundExitData else { continue }
            let counts = [
                ("memory limit", exits.cumulativeMemoryResourceLimitExitCount),
                ("watchdog (main thread blocked)", exits.cumulativeAppWatchdogExitCount),
                ("bad memory access", exits.cumulativeBadAccessExitCount),
                ("illegal instruction", exits.cumulativeIllegalInstructionExitCount),
                ("other abnormal exit", exits.cumulativeAbnormalExitCount),
            ].filter { $0.1 > 0 }
            guard !counts.isEmpty else { continue }
            let lines = counts.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            CrashLog.store(exitSummary: """
                EXITS WHILE ON SCREEN, \(payload.timeStampBegin) to \(payload.timeStampEnd)
                \(lines)
                """)
        }
        #endif
    }
}
#endif

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

    fileprivate static func fileUnexpectedExit(_ running: URL, caughtCrash: Bool, into directory: URL) {
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
    fileprivate static func installAlternateStack() {
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
