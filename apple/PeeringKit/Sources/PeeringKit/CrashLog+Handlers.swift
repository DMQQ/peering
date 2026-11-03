import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

// MARK: - The handler

/// The signals worth catching. `SIGKILL` is absent on purpose: the watchdog and the system kill the
/// process rather than crashing it, and nothing in the process is given the chance to run. That is
/// the half MetricKit covers and this half cannot.
let handledSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

/// A C string per handled signal, so the handler has something to write without formatting it.
nonisolated(unsafe) private var signalHeaders: [UnsafeMutablePointer<CChar>?] =
    Array(repeating: nil, count: Int(NSIG))

nonisolated(unsafe) private var commonHeader: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var pendingPath: UnsafeMutablePointer<CChar>?

/// The same file as ``pendingPath``, as something Swift can open.
nonisolated(unsafe) private var exceptionLogURL: URL?

/// Writes an uncaught exception where the next launch will file it.
func installExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let text = """
            EXCEPTION \(exception.name.rawValue)
            \(exception.reason ?? "no reason given")
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
        if let url = exceptionLogURL { append(text, to: url) }
    }
}

func prepareHandlerState(pending: URL, subject: String, version: String) {
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
func handleSignal(_ signalNumber: Int32) {
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
let metricCollector = MetricKitCollector()

/// `@unchecked Sendable` because it has no state to race on: it is a name for the two callbacks and
/// nothing else. `MXMetricManager` holds its subscriber weakly, which is why `install` keeps this
/// one alive itself.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
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
